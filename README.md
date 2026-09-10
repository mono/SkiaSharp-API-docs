# SkiaSharp and HarfBuzzSharp API Docs

This repository is the generated staging input for Microsoft Learn/OpenPublishing API reference content for [SkiaSharp and HarfBuzzSharp](https://github.com/mono/SkiaSharp). The ECMA XML is regenerated from the published NuGet package set; it does not require a SkiaSharp checkout or submodule.

Run `pwsh ./eng/Setup-ApiDocs.ps1` to acquire the latest `_NuGets` and `_DocsMedia` packages into `.artifacts/api-docs/packages`. By default, it uses `dotnet-libraries-transport`; pass `-PackageSource <local-NuGet-folder>` to use a local source containing those artifacts. Then run `pwsh ./eng/Generate-ApiDocs.ps1`, which assumes that prepared package directory and required .NET reference packs already exist. It invokes `eng/MDoc.ps1`, which downloads mdoc from `dotnet-public` only if its local tool cache is absent and forwards the mdoc command. The generator keeps only OpenPublishing infrastructure (`docfx.json`, filters, and breadcrumbs), regenerates framework moniker indexes, imports compiler XML documentation shipped in the NuGet packages, and promotes ECMA XML and media entirely from package content.

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
