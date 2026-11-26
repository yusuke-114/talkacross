import Accelerate
import Foundation

// Inference for the pinned Marian checkpoint. The encoder and decoder share an embedding table.
nonisolated struct ShanghaineseMarian {
    private static let width = 512
    private static let headWidth = 64
    private static let vocabularySize = 65_001

    private let data: Data
    private let tensors: [String: Tensor]
    private let dataOffset: Int

    private struct Tensor: Decodable {
        let dtype: String
        let shape: [Int]
        let data_offsets: [Int]
    }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let headerSize = data.withUnsafeBytes { bytes in
            bytes.count >= 8 ? UInt64(littleEndian: bytes.loadUnaligned(as: UInt64.self)) : 0
        }
        guard headerSize > 0, headerSize <= 1_048_576, headerSize <= data.count - 8,
              headerSize.isMultiple(of: UInt64(MemoryLayout<Float>.alignment)) else {
            throw ShanghaineseNormalizationIssue.invalidPack
        }
        let dataOffset = 8 + Int(headerSize)
        let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 8..<dataOffset))
        self.data = data
        self.dataOffset = dataOffset
        tensors = header.tensors
    }

    private struct Header: Decodable {
        let tensors: [String: Tensor]

        init(from decoder: any Decoder) throws {
            let entries = try decoder.container(keyedBy: Key.self)
            var tensors: [String: Tensor] = [:]
            for key in entries.allKeys where key.stringValue != "__metadata__" {
                tensors[key.stringValue] = try entries.decode(Tensor.self, forKey: key)
            }
            self.tensors = tensors
        }

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
    }

    func generate(from tokens: [Int64]) throws -> [Int64] {
        try data.withUnsafeBytes { bytes in
            let weights = Weights(bytes: bytes, dataOffset: dataOffset, tensors: tensors)
            return try weights.generate(from: tokens)
        }
    }

    private struct AttentionMemory {
        var keys: [Float] = []
        var values: [Float] = []
    }

    private struct Weights {
        let bytes: UnsafeRawBufferPointer
        let dataOffset: Int
        let tensors: [String: Tensor]

        func generate(from tokens: [Int64]) throws -> [Int64] {
            let embeddings = try tensor("model.shared.weight", shape: [vocabularySize, width])
            let positions = (0..<(width / 2)).map { pow(10_000.0, -Double($0) / Double(width / 2)) }
            var encoded = tokens.enumerated().flatMap { index, token in
                embedding(token, at: index, table: embeddings, frequencies: positions)
            }
            let encoderLayers = (0..<6).map { "model.encoder.layers.\($0)" }
            for layer in encoderLayers {
                try Task.checkCancellation()
                let memory = try projectAttention(encoded, from: layer + ".self_attn")
                encoded = try attend(encoded, memory: memory, layer: layer, name: "self_attn")
                encoded = try feedForward(encoded, layer: layer)
            }

            let decoderLayers = (0..<6).map { "model.decoder.layers.\($0)" }
            let crossAttention = try decoderLayers.map {
                try projectAttention(encoded, from: $0 + ".encoder_attn")
            }
            var selfAttention = decoderLayers.map { _ in AttentionMemory() }
            var output: [Int64] = []
            var token = ShanghaineseTokenizer.paddingToken
            for position in 0..<min(ShanghaineseTokenizer.maximumTokens - 1, tokens.count * 3 + 16) {
                try Task.checkCancellation()
                var hidden = embedding(token, at: position, table: embeddings, frequencies: positions)
                for (index, layer) in decoderLayers.enumerated() {
                    let current = try projectAttention(hidden, from: layer + ".self_attn")
                    selfAttention[index].keys.append(contentsOf: current.keys)
                    selfAttention[index].values.append(contentsOf: current.values)
                    hidden = try attend(hidden, memory: selfAttention[index], layer: layer, name: "self_attn")
                    hidden = try attend(hidden, memory: crossAttention[index], layer: layer, name: "encoder_attn")
                    hidden = try feedForward(hidden, layer: layer)
                }
                let logits = try project(
                    hidden, width: width, weights: embeddings, bias: tensor("final_logits_bias", shape: [1, vocabularySize]),
                    outputWidth: vocabularySize
                )
                // Marian excludes the padding token from generation.
                var next = 0
                for index in 1..<Int(ShanghaineseTokenizer.paddingToken) where logits[index] > logits[next] {
                    next = index
                }
                token = Int64(next)
                if token == ShanghaineseTokenizer.endToken { return output }
                output.append(token)
            }
            throw ShanghaineseNormalizationIssue.noConversion
        }

        private func tensor(_ name: String, shape: [Int]) throws -> UnsafePointer<Float> {
            let byteCount = shape.reduce(1, *) * MemoryLayout<Float>.stride
            guard let tensor = tensors[name], tensor.dtype == "F32", tensor.shape == shape,
                  tensor.data_offsets.count == 2 else {
                throw ShanghaineseNormalizationIssue.invalidPack
            }
            let start = tensor.data_offsets[0]
            let end = tensor.data_offsets[1]
            guard start >= 0, end >= start, end <= bytes.count - dataOffset, end - start == byteCount,
                  start.isMultiple(of: MemoryLayout<Float>.alignment), let baseAddress = bytes.baseAddress else {
                throw ShanghaineseNormalizationIssue.invalidPack
            }
            return baseAddress.advanced(by: dataOffset + start).assumingMemoryBound(to: Float.self)
        }

        private func embedding(
            _ token: Int64, at position: Int, table: UnsafePointer<Float>, frequencies: [Double]
        ) -> [Float] {
            let row = table.advanced(by: Int(token) * width)
            let scale = sqrt(Float(width))
            let half = width / 2
            return (0..<width).map { index in
                let angle = Double(position) * frequencies[index % half]
                let offset = Float(index < half ? sin(angle) : cos(angle))
                return row[index] * scale + offset
            }
        }

        private func linear(
            _ input: [Float], width inputWidth: Int, outputWidth: Int, name: String
        ) throws -> [Float] {
            let weights = try tensor(name + ".weight", shape: [outputWidth, inputWidth])
            let bias = try tensor(name + ".bias", shape: [outputWidth])
            return project(input, width: inputWidth, weights: weights, bias: bias, outputWidth: outputWidth)
        }

        private func project(
            _ input: [Float], width inputWidth: Int, weights: UnsafePointer<Float>,
            bias: UnsafePointer<Float>, outputWidth: Int
        ) -> [Float] {
            let rows = input.count / inputWidth
            let biasRow = UnsafeBufferPointer(start: bias, count: outputWidth)
            var output = [Float]()
            output.reserveCapacity(rows * outputWidth)
            for _ in 0..<rows {
                output.append(contentsOf: biasRow)
            }
            if rows == 1 {
                cblas_sgemv(
                    CblasRowMajor, CblasNoTrans, Int32(outputWidth), Int32(inputWidth),
                    1, weights, Int32(inputWidth), input, 1, 1, &output, 1
                )
            } else {
                cblas_sgemm(
                    CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(outputWidth), Int32(inputWidth),
                    1, input, Int32(inputWidth), weights, Int32(inputWidth), 1, &output, Int32(outputWidth)
                )
            }
            return output
        }

        private func projectAttention(_ input: [Float], from name: String) throws -> AttentionMemory {
            try AttentionMemory(
                keys: linear(input, width: width, outputWidth: width, name: name + ".k_proj"),
                values: linear(input, width: width, outputWidth: width, name: name + ".v_proj")
            )
        }

        private func attend(
            _ input: [Float], memory: AttentionMemory, layer: String, name: String
        ) throws -> [Float] {
            let prefix = layer + "." + name
            let queries = try linear(input, width: width, outputWidth: width, name: prefix + ".q_proj")
            let rows = Int32(input.count / width)
            let contextRows = Int32(memory.keys.count / width)
            let stride = Int32(width)
            let head = Int32(headWidth)
            let scale = 1 / sqrt(Float(headWidth))
            var scores = [Float](repeating: 0, count: Int(rows * contextRows))
            var result = [Float](repeating: 0, count: input.count)

            queries.withUnsafeBufferPointer { queries in
                memory.keys.withUnsafeBufferPointer { keys in
                    memory.values.withUnsafeBufferPointer { values in
                        result.withUnsafeMutableBufferPointer { result in
                            for offset in Swift.stride(from: 0, to: width, by: headWidth) {
                                cblas_sgemm(
                                    CblasRowMajor, CblasNoTrans, CblasTrans, rows, contextRows, head, scale,
                                    queries.baseAddress! + offset, stride, keys.baseAddress! + offset, stride,
                                    0, &scores, contextRows
                                )
                                softmax(&scores, width: Int(contextRows))
                                cblas_sgemm(
                                    CblasRowMajor, CblasNoTrans, CblasNoTrans, rows, head, contextRows, 1,
                                    scores, contextRows, values.baseAddress! + offset, stride,
                                    0, result.baseAddress! + offset, stride
                                )
                            }
                        }
                    }
                }
            }
            let projected = try linear(result, width: width, outputWidth: width, name: prefix + ".out_proj")
            return try residualNorm(input, projected, name: prefix + "_layer_norm")
        }

        private func softmax(_ values: inout [Float], width: Int) {
            for start in stride(from: 0, to: values.count, by: width) {
                let row = start..<(start + width)
                let maximum = values[row].max()!
                var sum: Float = 0
                for index in row {
                    values[index] = exp(values[index] - maximum)
                    sum += values[index]
                }
                for index in row { values[index] /= sum }
            }
        }

        private func feedForward(_ input: [Float], layer: String) throws -> [Float] {
            let expanded = try linear(input, width: width, outputWidth: 2048, name: layer + ".fc1")
            let activated = expanded.map { $0 / (1 + exp(-$0)) }
            let projected = try linear(activated, width: 2048, outputWidth: width, name: layer + ".fc2")
            return try residualNorm(input, projected, name: layer + ".final_layer_norm")
        }

        private func residualNorm(_ input: [Float], _ update: [Float], name: String) throws -> [Float] {
            let scales = try tensor(name + ".weight", shape: [width])
            let biases = try tensor(name + ".bias", shape: [width])
            var result = vDSP.add(input, update)
            for start in stride(from: 0, to: result.count, by: width) {
                let row = start..<(start + width)
                let mean = result[row].reduce(0, +) / Float(width)
                var variance: Float = 0
                for index in row {
                    result[index] -= mean
                    variance += result[index] * result[index]
                }
                let inverseDeviation = 1 / sqrt(variance / Float(width) + 1e-5)
                for column in 0..<width {
                    result[start + column] = result[start + column] * inverseDeviation * scales[column] + biases[column]
                }
            }
            return result
        }
    }
}
