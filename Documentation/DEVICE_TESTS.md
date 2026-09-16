# 真機驗收清單

此清單目前尚未完成。請記錄 iPhone 型號、iOS 版本、commit、簽署方式與 LocalDevVPN 版本；不要附上配對紀錄、憑證或私人路線。

## 建置與安裝

- [ ] PR 的 RouteCore 與 iOS archive 檢查通過。
- [ ] SideStore 重簽與安裝成功，Developer Mode 與配對正常。
- [ ] 系統顯示 iFakeGPS，bundle ID 不與原版重複。
- [ ] 未同時安裝使用相同 callback scheme 的 Roam Control。
- [ ] build artifact 包含上游授權與第三方聲明。

## 路線與儲存

- [ ] 從桌面 iFakeGPS 匯出 GPX，再由手機 Files 匯入。
- [ ] 單段、多段、route-only、waypoint-only GPX 的路線數與座標正確。
- [ ] 無效座標、畸形 XML、DTD／entity、超大檔案顯示錯誤且不覆寫路線庫。
- [ ] 儲存、重新命名、刪除、重新開啟 App 後資料一致。
- [ ] 匯出 GPX 可在桌面 iFakeGPS 重新匯入。
- [ ] 地圖預覽路線與實際播放一致。

## 定位與播放

- [ ] 從 idle 與既有 fixed session 啟動路線都能正常播放。
- [ ] 在另一個位置相關 App 驗證系統定位，不只看本 App 標記。
- [ ] 0.1、5、50 km/h 與 0%、50% 速度變化正常。
- [ ] 暫停／繼續不回到起點，也不把暫停時間計入距離。
- [ ] 往返循環在端點反向，不瞬移到另一端。
- [ ] 中途修改速度與循環設定不跳動。
- [ ] 反覆 Start／Stop 不留下第二個播放 task。
- [ ] 定位更新失敗時顯示錯誤，且不繼續推進進度。

## 背景、中斷與還原

- [ ] 切換 App、鎖屏、低電量、Wi-Fi／行動網路切換逐一測試。
- [ ] 排程停頓超過 5 秒後呈現暫停，使用者繼續前不補跑整段距離。
- [ ] VPN 中斷及權限撤銷的錯誤可處理。
- [ ] 每種失敗情境都可 Stop & Restore，並在另一個 App 確認真實位置回復。
- [ ] 強制結束 App 後的恢復流程不把 GPX 重新規劃為不同的 MapKit 路線。
- [ ] 停止或取消後，晚到的 callback 不重新啟動播放。
- [ ] 不保證無限背景運行；紀錄實測持續時間與電量影響。

## 隱私與介面

- [ ] 在 telemetry 開關開／關狀態，都不向上游統計服務送出資料。
- [ ] 檔案選取器與 security-scoped URL 在 Files／iCloud Drive 正常。
- [ ] 大字體、VoiceOver、直向小螢幕下，可操作暫停與 Stop & Restore。

完成真機驗收前，不把此版本標記為穩定版，也不把單元測試結果當成背景定位保證。
