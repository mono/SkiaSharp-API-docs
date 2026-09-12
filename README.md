# SkiaSharp and HarfBuzzSharp API Docs

This repository is the generated staging input for Microsoft Learn/OpenPublishing API reference content for [SkiaSharp and HarfBuzzSharp](https://github.com/mono/SkiaSharp). The ECMA XML is regenerated from the published NuGet package set; it does not require a SkiaSharp checkout or submodule.

Run `pwsh ./eng/Setup-ApiDocs.ps1` to acquire the latest `_NuGets` package and required `_DocsMedia` into `artifacts/api-docs/packages`. It uses `dotnet-libraries-transport` for those transport artifacts and `dotnet-public` for an explicit allowlist of third-party and platform reference packages; pass `-TransportPackageSource <local-NuGet-folder>` to replace the transport feed with a local CI-artifact folder. The platform reference packages replace SDK workload installation. Downloaded package versions are cached once in `artifacts/api-docs/downloads` and copied into the clean product and dependency workspaces on subsequent runs. Then run `pwsh ./eng/Generate-ApiDocs.ps1`. It invokes `eng/MDoc.ps1`, which downloads mdoc from `dotnet-public` only if its local tool cache is absent and forwards the mdoc command. The generator retains its conversion workspace for review, requires paired DLL/XML documentation input for every managed assembly it generates, uses mdoc `fx-bootstrap` to generate framework-scoped imports, regenerates framework moniker indexes, and promotes ECMA XML and media entirely from package content while retaining only OpenPublishing infrastructure (`docfx.json`, filters, and breadcrumbs).

For a fresh local test, run `pwsh ./eng/Clean-ApiDocs.ps1` before setup. It clears generated documentation plus all disposable API-doc artifacts, but never clears `artifacts/api-docs/downloads`.

The docs are available online for:
 - [SkiaSharp](https://docs.microsoft.com/dotnet/api/skiasharp)
 - [HarfBuzzSharp](https://docs.microsoft.com/dotnet/api/harfbuzzsharp)
 - [Skottie (SkiaSharp + Lottie)](https://docs.microsoft.com/dotnet/api/skiasharp.skottie)


## Microsoft Open Source Code of Conduct

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.


## Legal Notices

Microsoft and any contributors grant you a license to the Microsoft documentation and other content in this repository under the Creative Commons Attribution 4.0 International Public License, see the LICENSE file, and grant you a license to any code in the repository under the MIT License, see the LICENSE-CODE file.

Microsoft, Windows, Microsoft Azure and/or other Microsoft products and services referenced in the documentation may be either trademarks or registered trademarks of Microsoft in the United States and/or other countries. The licenses for this project do not grant you rights to use any Microsoft names, logos, or trademarks. Microsoft's general trademark guidelines can be found at http://go.microsoft.com/fwlink/?LinkID=254653.

Privacy information can be found at https://privacy.microsoft.com/en-us/

Microsoft and any contributors reserve all others rights, whether under their respective copyrights, patents, or trademarks, whether by implication, estoppel or otherwise.
