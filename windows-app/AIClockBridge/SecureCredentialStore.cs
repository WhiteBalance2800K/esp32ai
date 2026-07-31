using System.Runtime.InteropServices;

namespace AIClockBridge;

// Stores the optional Kimi API key in Windows Credential Manager. Only
// non-secret display preferences remain in settings.json.
static class SecureCredentialStore
{
    const string Target = "AIClockBridge/KimiCodeAPIKey";
    const uint CredTypeGeneric = 1;
    const uint CredPersistLocalMachine = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Credential
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode,
        SetLastError = true)]
    static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode,
        SetLastError = true)]
    static extern bool CredWrite(ref Credential credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode,
        SetLastError = true)]
    static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr buffer);

    public static string LoadKimiApiKey()
    {
        if (!OperatingSystem.IsWindows()) return null;
        if (!CredRead(Target, CredTypeGeneric, 0, out var ptr)) return null;
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(ptr);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0) return null;
            var value = Marshal.PtrToStringUni(
                credential.CredentialBlob, checked((int)credential.CredentialBlobSize / 2));
            return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
        }
        finally
        {
            CredFree(ptr);
        }
    }

    public static bool SaveKimiApiKey(string value)
    {
        if (!OperatingSystem.IsWindows()) return false;
        var cleaned = value?.Trim() ?? "";
        if (cleaned.Length == 0)
        {
            if (CredDelete(Target, CredTypeGeneric, 0)) return true;
            return Marshal.GetLastWin32Error() == 1168; // ERROR_NOT_FOUND
        }
        var ptr = Marshal.StringToCoTaskMemUni(cleaned);
        try
        {
            var credential = new Credential
            {
                Type = CredTypeGeneric,
                TargetName = Target,
                CredentialBlob = ptr,
                CredentialBlobSize = checked((uint)(cleaned.Length * 2)),
                Persist = CredPersistLocalMachine,
                UserName = Environment.UserName,
            };
            return CredWrite(ref credential, 0);
        }
        finally
        {
            Marshal.ZeroFreeCoTaskMemUnicode(ptr);
        }
    }
}
