# Lime 1.0

파일을 끄는 도중 키를 한 번 탭하면 휠이 떠서, 거기서 변환·편집·정리를 하는 macOS 메뉴 막대 앱입니다. 색과 아이콘 모두 라임을 씁니다.

## 실행

1. 같은 드래그 단축키를 쓰는 다른 앱이 있으면 종료합니다. 휠이 겹칩니다.
2. `../Lime.app`을 엽니다. 처음 실행하면 소개 창이 뜹니다. 이후 설정은 메뉴 막대 아이콘에서 엽니다.
3. Finder에서 파일을 끄는 동안 키를 한 번 탭합니다.
   - **⇧ Shift**: 변환 휠
   - **⌘ Command**: 도구 휠
   - **⌃ Control**: 동작 휠
4. 키에서 손을 떼도 휠은 남아 있습니다. 원하는 조각 위에 놓으면 실행되고, 가운데나 바깥에 놓으면 취소됩니다. 휠이 떠 있을 때 다른 키를 탭하면 그 휠로 바뀝니다.
5. 결과는 원본 옆에 `이름.확장자`로 저장됩니다. 도구 결과는 `이름 (smaller).jpg`처럼 괄호 꼬리표가 붙고, 이름이 겹치면 `이름 (smaller) 2.jpg`가 됩니다. 원본은 그대로 둡니다.

Apple silicon과 macOS 13 이상이 필요합니다. 로컬 ad-hoc 서명 빌드라서 처음 열 때 우클릭 → 열기가 필요할 수 있습니다.

## 기능

- **변환 269개 경로**: 이미지 8종, 오디오 8종, 비디오 6종과 GIF, PDF, DOCX/Pages/Markdown/RTF/RTFD/텍스트 클리핑/TXT/EPUB, PPT/PPTX, XLSX/XLS/ODS/CSV/TSV, SRT/VTT, ZIP/TAR/GZIP/RAR. RAR, PPT, XLS, RTF, RTFD, 텍스트 클리핑, WEBM은 읽기만 합니다. 전체 표는 설정 › Conversions에 있습니다.
- **도구 27개**: Shrink(프리셋·목표 크기·비율), Tags(메타데이터 편집/삭제), Adjust(21개 슬라이더), Mark Up(화살표·선·상자·원·텍스트·펜·형광펜·번호·돋보기·그림), Backdrop(그라데이션 12종·단색 12종·이미지), Crop(비율·정확한 픽셀), Scan Code, Mask(얼굴·글자 자동 감지), Level Loudness, Silence, Cut(조용한 앞뒤 자동 제거), PDF Pages/Reorder/Combine, Pictures to PDF, Unpack, 클립 Crop·Tempo·Stitch·Stills·Slice·Mask, Waveform Video, Mono/Stereo, Censor, Mosaic.
- **편집 창 조작**: Censor·Mask 구간은 끌어서 옮기고 양 끝으로 길이를 바꿉니다. 우클릭으로 "현재 위치부터"·"클립 전체"를 고르고, Delete로 지우고, 시작/끝을 초 단위로 입력할 수 있습니다. Slice에서 조각을 빼면 나머지를 한 클립(Save as One Clip)으로 저장하거나 따로 저장합니다. Mark Up에는 크기 핸들, 텍스트 폭 조절, Erase Ink, 돋보기 배율, ⌘V 이미지 붙여넣기가 있습니다. 컷 핸들은 화살표 키로 0.01초씩 움직입니다. 움직이는 WebP는 줄여도 애니메이션이 유지됩니다.
- **선택 도구**: 도구 휠 맨 뒤에 붙습니다. 설정 › Basics의 "Extra tools"로 켜고 끕니다.
  - **GRAB TEXT**: 이미지·GIF·PDF의 글자를 기기 안에서 인식해(한국어·영어·일본어·중국어) 바로 클립보드에 복사하고 결과 창을 띄웁니다. 텍스트가 있는 PDF는 텍스트 레이어를 쓰고, 스캔 페이지만 OCR합니다. 저장하면 `이름 (text).txt`가 됩니다. 여러 파일도 한 번에 됩니다.
  - **CUT OUT**: 사진의 사람·동물·사물을 찾아 배경을 지운 투명 PNG(`이름 (cutout).png`)를 만듭니다. macOS 14 이상에서 됩니다.
- **동작 6개**: Shelf, Copy To, Move To, AirDrop, Path(경로 복사), Shell(Terminal/iTerm2 열기).
- **Shelf**: 위쪽에 라임 탭이 달린 보관 카드입니다. 아이콘/목록 보기, 빈 곳을 끌어 여러 개 선택, 여러 파일 한 번에 끌어내기, 파일을 놓아 추가, 접기, 화면 가장자리에 붙이기, Space로 Quick Look을 지원합니다.
- **설정**: Basics(Glass/Solid, 로그인 시 실행, 소리·햅틱, 휠별 키 조합, Shelf 동작, 터미널 앱), Outputs(형식별 품질·메타데이터·비트 깊이·압축·최대 영상 높이·EPUB/Office 레이아웃), Conversions(형식 표), Access(저장 위치·폴더 권한), About Lime.
- 진행 카드, 취소, 끝난 뒤 클릭하면 Finder에서 보기.

## 다른 앱 없이 동작

Pages, Keynote, Numbers, Word, PowerPoint, Excel 중 어느 것도 실행하지 않습니다.

- **PPT/PPTX → PDF/JPG/PNG**: macOS에 내장된 Office 미리보기 렌더러(Quick Look)로 그립니다.
- **Pages 읽기**: .pages 안의 IWA 아카이브에서 본문·제목·목록·굵게/기울임을 직접 읽습니다.
- **Pages 쓰기**: 앱에 든 템플릿의 본문을 바꿔 진짜 .pages 파일을 만듭니다. Pages에서 그대로 열립니다.
- **XLS**: 자체 BIFF8 해석기로 읽고, 실패하면 Quick Look 표를 읽습니다.

## 빌드와 테스트

```sh
./Scripts/BuildMediaTools.sh   # 처음 한 번: ffmpeg/ffprobe를 공개 소스에서 빌드해 Resources/Tools에 넣음
./build.sh   # ../Lime.app 생성
./test.sh    # 상호작용 340개, 변환 269개 경로, 도구 55개 검사
```

FFmpeg(LGPL)과 LAME, Opus, Vorbis, libvpx, libwebp는 `Scripts/BuildMediaTools.sh`로 공개 소스에서 직접 빌드했습니다. 라이선스는 `Resources/Licenses`에 있습니다. `Lime.app --render <폴더>`는 휠·설정·편집 창을 PNG로 그립니다.

## 아이콘

`swift Scripts/MakeIcon.swift <폴더>.iconset && iconutil -c icns <폴더>.iconset -o Resources/AppIcon.icns`로 다시 그릴 수 있습니다.
