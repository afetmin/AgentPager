using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using AgentPager.Core;

namespace AgentPager.Bridge;

internal static class PhoneTlsIdentity
{
    // Windows Schannel cannot use an ephemeral TLS key. Without PersistKeySet,
    // .NET releases the imported user key container when the certificate is disposed.
    private static X509KeyStorageFlags KeyStorage => OperatingSystem.IsWindows()
        ? X509KeyStorageFlags.UserKeySet : X509KeyStorageFlags.EphemeralKeySet;

    internal static X509Certificate2 LoadOrCreate() => LoadOrCreate(
        Path.Combine(AgentPagerPaths.DataRoot, "phone-tls-identity.bin"),
        bytes => PairingSecretStore.Crypt(bytes, protect: true),
        bytes => PairingSecretStore.Crypt(bytes, protect: false));

    internal static X509Certificate2 LoadOrCreate(string path, Func<byte[], byte[]> protect, Func<byte[], byte[]> unprotect)
    {
        if (File.Exists(path))
        {
            var bytes = unprotect(File.ReadAllBytes(path));
            X509Certificate2 existing;
            try { existing = new X509Certificate2(bytes, (string?)null, KeyStorage); }
            finally { CryptographicOperations.ZeroMemory(bytes); }
            if (!existing.HasPrivateKey || existing.NotBefore.ToUniversalTime() > DateTime.UtcNow)
            {
                existing.Dispose();
                throw new CryptographicException("Invalid phone TLS identity.");
            }
            if (existing.NotAfter.ToUniversalTime() > DateTime.UtcNow) return existing;
            existing.Dispose();
        }

        using var created = Create();
        var pfx = created.Export(X509ContentType.Pkcs12);
        try
        {
            // Persist only DPAPI ciphertext; publish the identity atomically before using it.
            var encrypted = protect(pfx);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllBytes(temporary, encrypted);
                File.Move(temporary, path, overwrite: true);
            }
            finally { File.Delete(temporary); }
            return new X509Certificate2(pfx, (string?)null, KeyStorage);
        }
        finally { CryptographicOperations.ZeroMemory(pfx); }
    }

    internal static X509Certificate2 Create()
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=AgentPager Bridge", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new Oid("1.3.6.1.5.5.7.3.1") }, false));
        // The QR pins this exact leaf independently of the selected LAN address.
        var now = DateTimeOffset.UtcNow;
        return request.CreateSelfSigned(now.AddDays(-1), now.AddYears(5));
    }

    internal static string Fingerprint(X509Certificate2 certificate) =>
        certificate.GetCertHashString(HashAlgorithmName.SHA256).ToLowerInvariant();
}