# LaceOver

macOS 26+ screen saver. When the Mac goes idle, the screen you were using freezes and lace covers it.

- Five lace themes (장미 · 은방울꽃 · 작약 · 넝쿨 · 픽셀), any thread colour, or weave lace from your own drawing
- Flow direction, speed, size; optional clock and date
- Every setting is also in System Settings ▸ Screen Saver ▸ Options
- Lace is woven on the Mac itself (Swift + Metal); nothing leaves it

## Install

Download the DMG from [Releases](https://github.com/lee-hansol-cy/laceover/releases), drag LaceOver into Applications, open it once.

## Build

```
brew install xcodegen
./run.sh
```

`run.sh` signs with a local self-signed identity named "OSG Lace Clock Dev"; create one in Keychain Access or change the name.
`tools/dmg/make_dmg.sh` builds the DMG.

© 2026 이한솔 · Lee HanSol · OFFSET GROUND. All rights reserved.
