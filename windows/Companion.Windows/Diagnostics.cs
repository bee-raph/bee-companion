namespace BeeCompanion.Windows;

internal static class Diagnostics
{
    private static readonly object Gate = new();
    public static void Write(string message)
    {
        try
        {
            lock (Gate)
            {
                var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BeeCompanion");
                Directory.CreateDirectory(directory);
                var path = Path.Combine(directory, "startup.log");
                if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024)
                    File.Move(path, Path.Combine(directory, "startup.previous.log"), true);
                File.AppendAllText(path, $"{DateTimeOffset.Now:O} [{Environment.ProcessId}] {message}{Environment.NewLine}");
            }
        }
        catch { /* Diagnostics must not introduce another failure during exception handling. */ }
    }
}
