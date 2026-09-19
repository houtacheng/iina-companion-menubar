# IINA Companion Menu

macOS 選單列上的 IINA Companion Remote 控制器。程式透過 WebSocket 連線至
IINA 的 Companion Remote 外掛，即使 IINA 不在最前方也能控制播放。

## 系統需求

- macOS 13 或更新版本
- IINA 與 Companion Remote 外掛

## 使用方式

1. 在 IINA 的「設定 → 外掛 → Companion Remote」取得 Port 與配對金鑰。
2. 啟動 `IINA Companion Menu.app`。
3. 點擊 macOS 右上角的播放圖示。
4. 展開「連線設定」，輸入 IINA Mac 的 IP、Port 與配對金鑰。
5. 按「儲存並重新連線」。同一台 Mac 請使用 `127.0.0.1`。

程式不顯示於 Dock；若要結束，請在選單列視窗底部按「結束」。

進度列可直接拖曳；放開時會精準定位到指定的播放位置。視窗底部會顯示目前版本，並可檢查、下載及安裝 GitHub Releases 上的新版本。每個 ZIP 更新檔必須同時提供同名的 `.sha256` 驗證檔。

控制介面也提供 0–100% 音量滑桿與固定顯示的播放清單。清單保留三首歌的顯示空間，超過三首時可捲動，並會標示目前項目與每個本機媒體檔的時間長度；點選任一項即可直接切換播放。

## 下載

請至 [GitHub Releases](https://github.com/houtacheng/iina-companion-menubar/releases) 下載最新版本。解壓縮後，將 `IINA Companion Menu.app` 移至「應用程式」資料夾即可。

## 建置

```sh
chmod +x build-app.sh
./build-app.sh
```

輸出位於 `release/IINA Companion Menu.app` 及 ZIP 安裝檔。
