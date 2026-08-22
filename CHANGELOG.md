# Changelog

All notable changes to this project are documented in this file.

## 1.0.0 - 2026-03-28

- Re-centered the default build around the original handheld security and signal-intelligence goal instead of gaming-first defaults.
- Set the shipped profile to `GAMES_PROFILE=lean` with PortMaster, DOSBox-X, FEX, and Wine disabled unless explicitly requested.
- Updated the launcher so optional entries only appear when the corresponding binaries or paths are present in the image.
- Isolated Python-heavy security tools such as SpiderFoot and theHarvester in dedicated virtual environments.
- Reworked multiple upstream download and packaging paths to reduce breakage from current Bookworm, Kali, and GitHub release drift.
- Added an official-source fallback build for Kismet when the Bookworm package path is incompatible.
- Corrected project documentation and Docker output references to the generated image name `ghOSt-RG35XXH-1.0.0.img.gz`.
