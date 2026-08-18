@echo off
setlocal

set WHISPER_DIR=D:\whisper
set LOG=%WHISPER_DIR%\whisper.log

cd /d "%WHISPER_DIR%"

echo [%date% %time%] Demarrage wyoming-faster-whisper >> "%LOG%"

call D:\miniconda3\condabin\conda.bat activate torchenv

python -m wyoming_faster_whisper ^
  --model large-v3-turbo ^
  --language fr ^
  --device cuda ^
  --compute-type float16 ^
  --beam-size 5 ^
  --uri tcp://0.0.0.0:10300 ^
  --data-dir "%WHISPER_DIR%\data" >> "%LOG%" 2>&1

echo [%date% %time%] Arret code %errorlevel% >> "%LOG%"
endlocal