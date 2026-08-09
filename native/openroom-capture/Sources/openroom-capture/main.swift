import ScreenCaptureKit
import CoreMedia
import Foundation

// 解決 docs/../README.md 施工順序 #9：macOS 系統音訊擷取。ScreenCaptureKit 抓的是
// 系統輸出的 loopback audio，不管 Teams 是網頁還是桌面 app 都收得到——不像瀏覽器
// getDisplayMedia 只能分享分頁/視窗音訊。
//
// 這支不是完整 app，是一支照 docs/protocol.md 講話的 WS client：跟 eval feeder、
// 瀏覽器前端共用同一份協定，好處是「測到的延遲算數」。

var meetingId = "native-\(Int(Date().timeIntervalSince1970))"
var host = "127.0.0.1"
var port = 8000
var scenario = "discussion"
var durationSec: Double? = nil
var verbose = false

var argIter = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIter.next() {
    switch a {
    case "--meeting-id": meetingId = argIter.next() ?? meetingId
    case "--host": host = argIter.next() ?? host
    case "--port": port = Int(argIter.next() ?? "") ?? port
    case "--scenario": scenario = argIter.next() ?? scenario
    case "--duration": durationSec = Double(argIter.next() ?? "")
    case "--verbose": verbose = true
    case "--help":
        print("""
        usage: openroom-capture [--meeting-id ID] [--host H] [--port P] \
        [--scenario discussion|interview] [--duration SEC] [--verbose]
        沒給 --duration 就一直錄到 Ctrl-C。
        """)
        exit(0)
    default:
        eprint("未知參數: \(a)")
        exit(2)
    }
}

let sem = DispatchSemaphore(value: 0)
signal(SIGINT, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSrc.setEventHandler { sem.signal() }
sigSrc.resume()

Task {
    do {
        let wsURL = URL(string: "ws://\(host):\(port)/ws/\(meetingId)")!
        let client = OpenRoomClient(url: wsURL)
        client.verbose = verbose
        client.sendStart(scenario: scenario)

        print("等 server ready…")
        var waited = 0.0
        while !client.readyReceived {
            try await Task.sleep(nanoseconds: 200_000_000)
            waited += 0.2
            if waited > 90 {
                eprint("❌ 90 秒沒等到 ready，放棄。後端有跑嗎？（python -m openroom.server）")
                exit(1)
            }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            eprint("❌ 找不到 display，沒辦法建立 capture filter（ScreenCaptureKit 的音訊擷取仍需綁一個 display/window）")
            exit(1)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.showsCursor = false
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 不需要畫面，1fps 省資源

        var frameIdx: UInt32 = 0
        let output = AudioOutput()
        output.onFrame = { pcm in
            client.sendFrame(pcm: pcm, tsMs: frameIdx * 100)
            frameIdx += 1
        }

        let delegate = StreamDelegate()
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "openroom.audio"))
        try await stream.startCapture()
        print("🎙️  系統音訊擷取中 → \(wsURL.absoluteString)（Ctrl-C 停止）")

        if let dur = durationSec {
            try await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000))
            sem.signal()
        }
        sem.wait()

        print("收工中…")
        try await stream.stopCapture()
        client.sendStop()
        // 給 server 一點時間把 done（跟最後一輪分析）送回來，不是無限等。
        var waitedDone = 0.0
        while !client.doneReceived, waitedDone < 15 {
            try await Task.sleep(nanoseconds: 200_000_000)
            waitedDone += 0.2
        }
        print("錄了 \(frameIdx * 100 / 1000) 秒音訊 → \(meetingId)")
        exit(0)
    } catch {
        eprint("❌ 擷取失敗: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
