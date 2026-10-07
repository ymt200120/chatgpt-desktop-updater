# Third-party notices

This project is an independent community project. It does not redistribute
ChatGPT binaries. ChatGPT and related product names and marks belong to their
respective owners.

## Structural design reference

Some structural ideas in the updater, including native architecture selection,
cross-validation before deployment, a deployment-held read lease, and HRESULT
guidance, were informed by the following upstream project:

- Project: [pavelbe/codex-windows-store-helper](https://github.com/pavelbe/codex-windows-store-helper)
- Referenced file: `scripts/Install-CodexDirect.ps1`
- Referenced commit: `bea80fb446e7b7f76f59dab33e6450519127f38d`
- Copyright: (c) 2026 Pavel

The implementation in this repository is independent. The upstream project is
licensed under the MIT License:

MIT License

Copyright (c) 2026 Pavel

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
