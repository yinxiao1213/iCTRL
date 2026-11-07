// 辨識截圖裡的文字，輸出 JSON：[{"label": 文字, "cx": 0~1, "cy": 0~1}]，座標原點在左上。
// runner 的 screen_text 會把系統對話框的字放進 overlay_text 而且沒有座標，測試按不到，
// 所以改在 Mac 上直接看模擬器的截圖。
import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count > 1,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("[]")
    exit(0)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US", "zh-Hant"]
try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
var items: [[String: Any]] = []
for observation in request.results ?? [] {
    guard let top = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox
    items.append(["label": top.string, "cx": box.midX, "cy": 1 - box.midY])
}
let data = try JSONSerialization.data(withJSONObject: items)
print(String(data: data, encoding: .utf8) ?? "[]")
