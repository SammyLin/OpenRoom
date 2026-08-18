import CryptoKit
import Foundation
import HuggingFace
import MLXAudioCore

/// 開會前先把模型抓下來，而且**抓的時候看得見**。
///
/// 之前 `STT.loadModel` / `SortformerModel.fromPretrained` 自己在背後下載，UI 只有一顆
/// 「Connecting…」轉圈：第一次啟動要抓 ~1GB，使用者分不出「在下載」跟「當掉了」。
/// 那是靜默降級的 UI 版——事情正在發生，畫面上沒有任何證據。
///
/// 實作上不自己寫下載器：呼叫的就是那兩個 `fromPretrained` 底下同一個
/// `ModelUtils.resolveOrDownloadModel`，只是多帶一個 `progressHandler`。所以抓完之後
/// 真正載入時走的是同一條 resolve 路徑，直接命中快取，不會抓第二遍；斷線留下的
/// `.incomplete` blob 也由套件自己續傳。
@MainActor
final class ModelStore: ObservableObject {
    struct Spec: Sendable {
        let repo: String
        let label: String
        /// false = 抓不到就沒有這個功能，但會議照開。逐字稿是產品，講者標籤是加分。
        let essential: Bool
    }

    /// 模型位址的唯一來源。預抓跟實際載入必須是同一個字串，差一個字就是抓兩遍
    /// 各 ~600MB，而且第二遍沒有進度條。
    nonisolated static let asr = Spec(repo: "mlx-community/Qwen3-ASR-0.6B-4bit",
                                      label: L("Transcription"), essential: true)
    /// `...-v2` 這個位址不存在（HF 回 401），所以講者分離從來沒有真的載入過——
    /// 只是每場會議吐一個 `speaker_error` 在旁邊，逐字稿全部掛在 spk_1 底下。
    /// 這是套件 README 裡的那個位址，也是 mlx-community 真的有的那個。
    nonisolated static let diarizer = Spec(repo: "mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16",
                                          label: L("Speaker labels"), essential: false)
    /// 下載順序：逐字稿比講者標籤重要，先抓 ASR。
    nonisolated static var required: [Spec] { [asr, diarizer] }

    enum Stage: Sendable { case downloading, verifying }

    /// 正在處理的模型；nil = 沒有下載在進行（快取全中的時候整段都是 nil）。
    @Published private(set) var fetching: String?
    @Published private(set) var stage: Stage = .downloading
    @Published private(set) var received: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var error: String?
    /// 預抓就沒抓到的 repo。非必要模型抓不到時會議照開，但別在開場再試一次同一個
    /// 抓不到的位址——使用者只會多等一輪 timeout，拿到同一個錯誤。
    private(set) var unavailable: Set<String> = []
    private(set) var unavailableReason: [String: String] = [:]

    /// 模型放在哪。使用者問「那 1GB 在我硬碟哪裡」時要答得出來，不然就只能猜。
    /// 跟 `ModelUtils.resolveOrDownloadModel` 寫入的位置是同一個。
    nonisolated static var directory: URL {
        HubCache.default.cacheDirectory.appendingPathComponent("mlx-audio", isDirectory: true)
    }

    nonisolated static func directory(for spec: Spec) -> URL {
        directory.appendingPathComponent(spec.repo.replacingOccurrences(of: "/", with: "_"),
                                         isDirectory: true)
    }

    /// 這份權重驗過了。驗完才寫這個檔，所以「下載完但還沒驗就被關掉」下次會重驗，
    /// 而不是被當成驗過的東西放行——後者正是套件那個「有一個非零 safetensors 就算數」
    /// 的弱檢查，這一層存在的理由就是不信它。
    ///
    /// 用 marker 不用「掃目錄有沒有 safetensors」：驗過一次就不必每次開 app 重新
    /// 雜湊 600MB，那是拿使用者的時間換一個已經回答過的問題。
    nonisolated static func verifiedMarker(_ spec: Spec) -> URL {
        directory(for: spec).appendingPathComponent(".openroom-verified")
    }

    nonisolated static func isVerified(_ spec: Spec) -> Bool {
        FileManager.default.fileExists(atPath: verifiedMarker(spec).path)
    }

    /// 給 UI 的一行字。有總大小才報進度百分比——沒有的時候寧可只說在抓什麼，
    /// 不要畫一條假的進度條。
    var statusLine: String? {
        guard let fetching else { return nil }
        if stage == .verifying { return String(format: L("Verifying %@…"), fetching) }
        guard total > 0 else { return String(format: L("Fetching %@…"), fetching) }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return String(format: L("Downloading %1$@ — %2$@ of %3$@"), fetching,
                      f.string(fromByteCount: received), f.string(fromByteCount: total))
    }

    var fraction: Double {
        total > 0 ? min(1, Double(received) / Double(total)) : 0
    }

    /// 把所有模型抓到位並驗過雜湊。全部命中快取時是個幾毫秒的 no-op。
    ///
    /// 回傳 false = 有模型沒到位，這時候不該開始收音（假裝開始只會錄一場沒有逐字稿的
    /// 會議）。`error` 是原因；使用者自己按取消的時候 `error` 是 nil——那不是故障。
    func prefetch() async -> Bool {
        error = nil
        unavailable = []
        unavailableReason = [:]
        defer { fetching = nil }
        for spec in Self.required {
            guard let repoID = Repo.ID(rawValue: spec.repo) else {
                guard spec.essential else {
                    unavailable.insert(spec.repo)
                    unavailableReason[spec.repo] = String(format: L("Invalid model repository: %@"),
                                                          spec.repo)
                    continue
                }
                error = String(format: L("Invalid model repository: %@"), spec.repo)
                return false
            }
            // 驗過的才跳過驗證。只是「檔案在那裡」不算——那正是我們不信的那個檢查。
            let wasVerified = Self.isVerified(spec)
            fetching = spec.label
            stage = .downloading
            received = 0
            total = 0
            note("fetching \(spec.repo) (verified: \(wasVerified))")
            do {
                _ = try await ModelUtils.resolveOrDownloadModel(
                    client: HubClient(cache: .default),
                    cache: .default,
                    repoID: repoID,
                    // 兩顆模型的 `fromPretrained` 都是這個值，改這裡會讓預抓跟實際載入
                    // 查不同的檔案，於是下載兩遍。
                    requiredExtension: "safetensors",
                    progressHandler: { [weak self] progress in
                        self?.received = progress.completedUnitCount
                        self?.total = progress.totalUnitCount
                    })
                if !wasVerified {
                    stage = .verifying
                    try await verify(spec)
                }
            } catch is CancellationError {
                // 使用者按了取消。留下的 `.incomplete` blob 下次續傳，不是垃圾。
                note("cancelled while fetching \(spec.repo)")
                return false
            } catch {
                guard !Task.isCancelled else {
                    note("cancelled while fetching \(spec.repo)")
                    return false
                }
                note("failed \(spec.repo): \(error)")
                // 非必要的模型抓不到，會議照開：沒有講者標籤的逐字稿還是逐字稿。
                // 缺這件事不會被吞掉——`Diarizer.start` 稍後會發 `speaker_error`，
                // LiveView 的管線健康那一欄看得到。
                guard spec.essential else {
                    unavailable.insert(spec.repo)
                    unavailableReason[spec.repo] = error.localizedDescription
                    continue
                }
                self.error = String(format: L("Could not download %1$@: %2$@"),
                                    spec.label, error.localizedDescription)
                return false
            }
            note("ready \(spec.repo)")
        }
        return true
    }

    // MARK: - 驗證

    /// 拿 Hugging Face 自己講的 LFS sha256 對一遍剛下載的權重。
    ///
    /// 這**不是** handy 那種「雜湊釘在執行檔裡」的信任錨——那要我們自己維護 catalog，
    /// 而 `mlx-community` 不是我們的 repo，上游一推新權重就會讓釘死的雜湊把 app 鎖死。
    /// 這裡防的是另一件事，也是實際會發生的那件：下載被截斷、磁碟寫壞、公司代理塞了
    /// 一頁 HTML 進來。套件本身只檢查「有一個非零位元組的 safetensors」，那個門檻低到
    /// 壞掉的檔案照樣過得去，然後在載入模型時炸成一個看不懂的錯誤。
    ///
    /// 對不上就把檔案刪掉，讓下一次從乾淨狀態重來——留著等於每次啟動都壞在同一個地方。
    private func verify(_ spec: Spec) async throws {
        let expected = try await Self.lfsHashes(repo: spec.repo)
        guard !expected.isEmpty else {
            // HF 沒給 LFS 資訊（小檔案不走 LFS）。沒得驗就說沒得驗，不要假裝驗過了。
            note("no LFS hashes advertised for \(spec.repo); skipping verification")
            return
        }
        let dir = Self.directory(for: spec)
        var checked = 0
        for (filename, wantHex) in expected {
            let url = dir.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let gotHex = try await Task.detached { try Self.sha256(of: url) }.value
            guard gotHex == wantHex else {
                try? FileManager.default.removeItem(at: url)
                note("sha256 mismatch for \(filename): want \(wantHex), got \(gotHex)")
                throw VerificationError.corrupt(filename)
            }
            checked += 1
        }
        guard checked > 0 else {
            // HF 說有 LFS 權重，磁碟上一個都對不上檔名——可能是巢狀路徑，也可能根本沒下載到。
            // 這種情況下說「驗過了」是假的，所以不留 marker，下次重驗。
            note("verified nothing for \(spec.repo): none of \(expected.count) advertised LFS file(s) found on disk")
            return
        }
        try? Data().write(to: Self.verifiedMarker(spec))
        note("verified \(checked) file(s) of \(spec.repo)")
    }

    enum VerificationError: LocalizedError {
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .corrupt(let filename):
                return String(format: L("%@ is corrupt; it has been removed, please try again."),
                              filename)
            }
        }
    }

    /// `filename -> sha256`，只給 repo 裡走 LFS 的檔案（權重就是這些）。
    /// 非 LFS 的小檔案 HF 只給 git blob sha1，那個對不上檔案內容的 sha256，所以不列。
    private static func lfsHashes(repo: String) async throws -> [String: String] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=1")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        var out: [String: String] = [:]
        for entry in entries {
            guard let path = entry["path"] as? String,
                  let lfs = entry["lfs"] as? [String: Any],
                  let oid = lfs["oid"] as? String, oid.count == 64 else { continue }
            out[path] = oid.lowercased()
        }
        return out
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        // 權重是幾百 MB，不能整份讀進記憶體。
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 下載這件事出問題的時候，使用者手上只有一個 .app。stderr 留一條線索，
    /// `Console.app` 跟 bug report 才有東西可看。進度不寫（每秒十幾行是噪音）。
    private nonisolated func note(_ message: String) {
        FileHandle.standardError.write(Data("openroom: models: \(message)\n".utf8))
    }
}
