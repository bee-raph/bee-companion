using BeeCompanion.Core;
using Windows.Security.Credentials;

namespace BeeCompanion.Windows;

/// PasswordVault delegates credential protection to the Windows account vault.
public sealed class SessionVault : ISessionVault
{
    private const string Resource = "BeeCompanion.Session";
    public Task<SessionTokens?> LoadAsync(string instanceId)
    {
        var vault = new PasswordVault();
        PasswordCredential credential;
        try { credential = vault.Retrieve(Resource, instanceId); }
        catch (System.Runtime.InteropServices.COMException e) when (e.HResult == unchecked((int)0x80070490))
        { return Task.FromResult<SessionTokens?>(null); }
        credential.RetrievePassword();
        return Task.FromResult<SessionTokens?>(Wire.Decode<SessionTokens>(credential.Password));
    }
    public Task SaveAsync(string instanceId, SessionTokens? tokens)
    {
        var vault = new PasswordVault();
        // Add replaces a credential with the same resource/username.
        if (tokens is not null) vault.Add(new PasswordCredential(Resource, instanceId, Wire.Encode(tokens)));
        else
        {
            try { vault.Remove(vault.Retrieve(Resource, instanceId)); }
            catch (System.Runtime.InteropServices.COMException e) when (e.HResult == unchecked((int)0x80070490)) { }
        }
        return Task.CompletedTask;
    }
}
