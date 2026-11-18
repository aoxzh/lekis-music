using Windows.Security.Credentials;

namespace Lekis.Core;

/// <summary>
/// 凭据存储（SRC-15）：Windows 凭据管理器（PasswordVault）。数据库里只存 key，密码只在这里。
/// 由 Rust 核心通过 UniFFI 回调接口调用，可能在任意线程上；PasswordVault 是线程安全的。
/// </summary>
public sealed class WindowsCredentialStore
{
    private const string Resource = "Lekis";
    private readonly PasswordVault _vault = new();

    public string? Get(string key)
    {
        try
        {
            var cred = _vault.Retrieve(Resource, key);
            cred.RetrievePassword();
            return cred.Password;
        }
        catch (Exception)
        {
            // PasswordVault 找不到条目时抛 COMException（ELEMENT_NOT_FOUND），这里统一当作"不存在"。
            return null;
        }
    }

    public bool Set(string key, string secret)
    {
        try
        {
            _vault.Add(new PasswordCredential(Resource, key, secret));
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public bool Delete(string key)
    {
        try
        {
            _vault.Remove(_vault.Retrieve(Resource, key));
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
