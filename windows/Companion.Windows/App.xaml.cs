using Microsoft.UI.Xaml;

namespace BeeCompanion.Windows;
public partial class App : Application
{
    private MainWindow? window;
    public App()
    {
        UnhandledException += (_, e) => Diagnostics.Write("Unhandled XAML exception: " + e.Message + "\n" + e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Diagnostics.Write("Unhandled runtime exception: " + e.ExceptionObject);
        Diagnostics.Write("Application resource initialization started");
        InitializeComponent();
        Diagnostics.Write("Application resources initialized");
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Diagnostics.Write("Creating main window");
        window = new MainWindow();
        window.Activate();
        Diagnostics.Write("Main window activated");
    }
}
