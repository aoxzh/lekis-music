# Generated/

`uniffi-bindgen-cs` generates `lekis_ffi.cs` here. **Do not commit it, and do not edit it by hand** (it is in .gitignore).

```powershell
cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.9.0+v0.28.3
./tools/gen-bindings.ps1
```

When this file is present, the project defines the `LEKIS_BINDINGS` compile symbol, `RustCoreService.cs` is compiled, and `CoreServiceFactory` returns the real core.
