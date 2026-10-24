# BitcoinMenu

- Bitcoin-Kurs in der macOS-Menüleiste
- EUR / USD · Kraken · Aktualisierung alle 30 Sekunden
- macOS 13+ · Swift / AppKit

## Installation

- [Download](https://github.com/theophieln/BitcoinMenu/releases/latest) · Apple Silicon
- DMG öffnen → App nach Programme ziehen
- Lokale Signatur · Keine Apple-Notarisierung
- Falls macOS den Start blockiert: Systemeinstellungen → Datenschutz & Sicherheit → Dennoch öffnen

## Build

- Apple Command Line Tools · Swift 6

```sh
./build.sh
./test.sh
./release.sh
```

- App: `build/BitcoinMenu.app` · DMG: `dist/BitcoinMenu.dmg`
- Build für die Architektur des jeweiligen Macs
- [MIT](LICENSE)
