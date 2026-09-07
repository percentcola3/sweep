# Third-party notices

## Mole

ForgeSweep includes source code derived from Mole:

- Project: https://github.com/tw93/Mole
- Vendored revision: `b5c6eccb24f4727da850a1a454aa0df45bb51216`
- License: GNU General Public License v3.0
- License text: [`vendor/mole/LICENSE`](vendor/mole/LICENSE)

The vendored source is kept in `vendor/mole/`. Local `bridge/app_*.sh` files
are ForgeSweep integration code and replace same-named GUI bridge resources at
build time. Only the audited helper libraries needed by optional specialty
bridges are packaged; ForgeSweep's clean, analyze, uninstall, optimize and
status paths run through its native Swift services.
