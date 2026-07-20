@echo off
setlocal

:: ========================================================
:: 設定エリア (環境に合わせて修正してください)
:: ========================================================

:: 1. 開発元のMQ4ファイルのパス (アップロードされた構成に基づき src\MQL4\Experts を付加しています)
set "SOURCE_FILE=I:\04_develop\rakuten-mt4-usdjpy-scalp-ma-rsi\src\MQL4\Experts\USDJPY_Scalp_MA_RSI.mq4"

:: 2. MT4のExpertsフォルダ (コピー先)
set "DEST_DIR=C:\Users\ryo\AppData\Roaming\MetaQuotes\Terminal\A84B568DA10F82FE5A8FF6A859153D6F\MQL4\Experts"

:: 3. MetaEditor.exe のパス (楽天MT4のインストール場所を確認してください)
:: ※標準的なインストール先を入れていますが、違う場合は書き換えてください
::set "METAEDITOR_PATH=C:\Program Files (x86)\Rakuten Securities Inc MetaTrader 4\metaeditor.exe"
set "METAEDITOR_PATH=C:\Program Files (x86)\Rakuten MetaTrader 4\metaeditor.exe"

:: ========================================================
:: 処理実行
:: ========================================================

echo [Step 1] Copying source file...
echo From: "%SOURCE_FILE%"
echo To:   "%DEST_DIR%"

:: /Y オプションで上書き確認をスキップ
copy /Y "%SOURCE_FILE%" "%DEST_DIR%\"

if %errorlevel% neq 0 (
    echo [ERROR] Failed to copy file.
    pause
    exit /b %errorlevel%
)
echo Copy successful.
echo.

echo [Step 2] Compiling with MetaEditor...
:: /compile:対象ファイル /log:ログファイル出力
"%METAEDITOR_PATH%" /compile:"%DEST_DIR%\USDJPY_Scalp_MA_RSI.mq4" /log:"%DEST_DIR%\USDJPY_Scalp_MA_RSI.log"

echo.
echo [Step 3] Checking compilation result...

:: ログファイルの内容を表示
if exist "%DEST_DIR%\USDJPY_Scalp_MA_RSI.log" (
    type "%DEST_DIR%\USDJPY_Scalp_MA_RSI.log"
    echo.
)

:: .ex4ファイルが更新されたか簡易チェック (本来はタイムスタンプ比較などが厳密ですが、ここではログ確認を推奨)
echo.
echo Done! Please check the log above for any errors (0 errors means success).
pause