// 보험라이브 증빙사진 글자인식 (Apple Vision, 이 Mac 안에서만 처리 · 외부 전송 없음)
// 사용: bl_ocr <이미지 경로>  → 표준출력 JSON {"width":..,"height":..,"lines":[{"text","conf","x","y","w","h"}]}
// 좌표는 0~1 비율, 왼쪽 위 기준.
import AppKit
import Foundation
import Vision

func fail(_ code: String) -> Never {
  FileHandle.standardError.write(code.data(using: .utf8)!)
  exit(2)
}

guard CommandLine.arguments.count == 2 else { fail("usage") }
guard let image = NSImage(contentsOfFile: CommandLine.arguments[1]) else { fail("unreadable_image") }
var rect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { fail("unreadable_image") }

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["ko-KR", "en-US"]
// 이름·번호를 사전 단어로 '고치지' 않도록 언어 보정은 끈다.
request.usesLanguageCorrection = false
do {
  try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
} catch {
  fail("ocr_failed")
}

var lines: [[String: Any]] = []
for observation in request.results ?? [] {
  guard let best = observation.topCandidates(1).first else { continue }
  let b = observation.boundingBox
  lines.append([
    "text": best.string,
    "conf": Double(best.confidence),
    "x": Double(b.minX),
    "y": Double(1 - b.maxY),
    "w": Double(b.width),
    "h": Double(b.height),
  ])
}
let result: [String: Any] = ["width": cg.width, "height": cg.height, "lines": lines]
let data = try! JSONSerialization.data(withJSONObject: result, options: [])
FileHandle.standardOutput.write(data)
