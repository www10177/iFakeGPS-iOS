# iFakeGPS-iOS

將桌面版 iFakeGPS 的路線功能移植到 iPhone，保留 Roam Control 的手機端配對、LocalDevVPN 與定位工作階段。

**這是第一階段開發版，不是已通過真機驗收的正式版本。** iOS App 需要 iOS 27+；RouteCore 的 Swift Package 可在 Linux 測試，並不表示整個 App 支援 iOS 17 或純 Linux 建置。

## 目前實作

| 功能 | 說明 |
| --- | --- |
| GPX 匯入／匯出 | 支援 track、route、waypoint；每個 track segment 分開匯入，不跨斷點連線。 |
| 路線庫 | 儲存、重新命名、刪除；使用有版本的 JSON 與 atomic write；損壞的資料庫不會被空資料覆寫。 |
| 路線播放 | 自訂 0.1–50 km/h、0–50% 速度變化、暫停／繼續、往返循環。 |
| 地圖整合 | 路線庫入口、GPX 折線、播放卡片；可儲存目前的 MapKit 路線。 |
| 中斷處理 | 單調時鐘；超過 5 秒的排程空檔會暫停。定位更新未被接受時不推進進度。 |
| CI | Linux 核心測試、Xcode 27 archive、未簽署 IPA artifact。實際建置結果以 PR checks 為準。 |

原有桌面版 `www10177/iFakeGPS` 不會被修改。桌面版與手機版先透過 GPX 交換路線，不共用 Python runtime 或 SQLite 檔案。

## 原始碼結構

- `Upstream/RoamControl`：Git submodule，鎖定 Build 61 的 `19b596e737639a7a7089b7d476eee848a3255559`。
- `Sources/RouteCore`：不依賴 MapKit 的幾何、播放、GPX 與路線儲存。
- `Integration`：SwiftUI 路線庫與替換的行走控制器。
- `scripts/prepare_app.py`：檢查上游 commit、工作樹與授權雜湊，產生 `.generated/RoamControl` 並套用整合。
- `scripts/build_ipa.sh`：使用 Xcode archive 打包，不提供 Apple 憑證。

不會追蹤或自動合併上游 `main`。產生目錄中的修改會被下一次 prepare 覆蓋；請修改 `Integration`、`Sources` 或整合腳本。

## 開發與測試

本 PR 尚未合併時，可直接取得開發分支：

```bash
git clone --recurse-submodules --branch feat/route-library-mvp https://github.com/www10177/iFakeGPS-iOS.git
cd iFakeGPS-iOS
swift test
python3 -m unittest discover -s scripts -p 'test_*.py'
```

一般 checkout 後缺少上游時：

```bash
git submodule update --init --recursive
```

本次本機驗證：Swift 6.2.1 / Linux，21 項 XCTest 通過；4 項 Python 整合錨點測試通過。另執行 Swift 語法解析與 shell 語法檢查。這些檢查**不等於** SwiftUI／MapKit 完整 type-check、iOS archive 或實機定位測試。

在具有 Xcode 27 與 iOS 27 SDK 的 Mac：

```bash
python3 scripts/prepare_app.py
open .generated/RoamControl/RoamControl.xcodeproj
# 或建立未簽署 IPA
bash scripts/build_ipa.sh
```

輸出：`dist/iFakeGPS-iOS-unsigned.ipa`。側載時仍需由 SideStore 等工具簽署；此專案不繞過 iOS 簽署要求。

PR 建立／更新與 main push 會觸發 GitHub Actions。iOS job 使用官方 `xcode-27` preview runner；可用性與費用依帳戶及 GitHub runner 政策。成功後在該次執行的 artifacts 取得 `iFakeGPS-iOS-unsigned`。手動 workflow dispatch 需 workflow 已存在於預設分支。

## 安裝與操作限制

需要 iOS 27+、Developer Mode、LocalDevVPN，以及完成本機配對。App 顯示名稱為 iFakeGPS，bundle ID 為 `com.www10177.ifakegps.ios`。

第一階段仍保留上游 callback URL scheme 與部分上游文案／圖示。**不要與原版 Roam Control 同時安裝**，以免 URL callback 被另一個 App 接收；完整重新命名列為後續工作。

GPX 匯入上限 5 MiB／50,000 點；路線庫上限 200 條／200,000 點／20 MiB。GPX 的海拔、時間戳與多段間的間隔不參與播放。

循環採用「沿原路折返」，不是從終點瞬移回起點。開始路線會先設定到第一個路點；抵達或暫停不代表真實定位已還原，結束時請使用 **Stop & Restore**。

背景執行及鎖屏持續性尚待真機驗證。App 被系統終止後，不會自動恢復 GPX 路線進度；上游恢復紀錄只保留定位工作階段，不將 GPX 重新規劃成另一條 MapKit 路線。先還原真實位置，再重新選擇路線。

產生的 Info.plist 會清空上游 telemetry endpoint、token、app ID 與 namespace。路線庫存在 App sandbox；備份行為仍由 iOS 設定決定。請勿把配對紀錄、Apple 憑證或私人 GPX 提交到 Git。

## 尚未完成

行走中追加路點、多點編輯器、OSRM／OpenRouteService、跨程序 GPX 進度恢復、完整品牌替換、完整繁體中文介面，以及真機回歸驗收。驗收項目見 `Documentation/DEVICE_TESTS.md`。

## 授權

整合基底為 **Roam Control 0.9.2 Preview Build 61 / PolyForm Noncommercial 1.0.0**，不是後續受限的 main。新增程式碼同樣以 PolyForm Noncommercial 1.0.0 提供；商業使用不在此授權範圍內。

保留 `NOTICE`、上游完整授權與第三方聲明；建置時把上游授權文件放入 App resource。第三方元件維持原授權。上游歷史版本的授權不代表後续 main 可以自由合併；任何升級都必須重新審查。
