using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace Winoid {
    // Tiny replacement for the deprecated VBScript launcher. Starts the
    // hidden manager, then restarts it only if it exits without a clean
    // shutdown request. The manager writes shutdown.request from its Closing
    // handler, so closing the Winoid window stops the watchdog instead of
    // bringing the app back a few seconds later.
    internal static class Launcher {
        [STAThread]
        private static void Main(string[] args) {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(dir, "Winoid.ps1");
            string data = Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData), "Winoid");
            try { Directory.CreateDirectory(data); } catch { }
            string shutdown = Path.Combine(data, "shutdown.request");
            string legacyQuit = Path.Combine(data, "quit.request");

            if (!File.Exists(script)) {
                MessageBox.Show("Winoid.ps1 not found in " + dir, "Winoid",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // Remember the original arguments for the very first start only.
            // A watchdog restart must not silently relaunch the game again.
            string[] firstArgs = args;
            bool first = true;
            for (;;) {
                try {
                    if (File.Exists(shutdown)) File.Delete(shutdown);
                    if (File.Exists(legacyQuit)) File.Delete(legacyQuit);
                } catch { }

                Process proc;
                try {
                    var psi = new ProcessStartInfo();
                    psi.FileName = FindPwsh();
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    psi.WindowStyle = ProcessWindowStyle.Hidden;
                    psi.Arguments =
                        "-NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Q(script);
                    foreach (string a in (first ? firstArgs : new string[0])) psi.Arguments += " " + Q(a);
                    proc = Process.Start(psi);
                } catch (Exception ex) {
                    MessageBox.Show("Could not start PowerShell 7.\n" + ex.Message +
                        "\n\nInstall PowerShell 7 from https://aka.ms/powershell",
                        "Winoid", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }

                proc.WaitForExit();
                proc.Dispose();
                first = false;
                try {
                    string log = Path.Combine(data, "launcher.log");
                    var fi = new FileInfo(log);
                    if (fi.Exists && fi.Length > 1048576) File.Delete(log);
                    File.AppendAllText(log, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") +
                        " manager exited; restart=" + !(File.Exists(shutdown) || File.Exists(legacyQuit)) + Environment.NewLine);
                } catch { }
                Thread.Sleep(2500);

                bool clean = false;
                try { clean = File.Exists(shutdown) || File.Exists(legacyQuit); } catch { }
                if (clean) break;
            }
        }

        private static string FindPwsh() {
            string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string known = Path.Combine(pf, "PowerShell", "7", "pwsh.exe");
            return File.Exists(known) ? known : "pwsh.exe";
        }

        // Windows CommandLineToArgvW quoting: double backslashes before a
        // quote or at the end, escape quotes, wrap the argument in quotes.
        private static string Q(string value) {
            var sb = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value) {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') {
                    sb.Append('\\', slashes * 2 + 1);
                    sb.Append('"');
                } else {
                    sb.Append('\\', slashes);
                    sb.Append(c);
                }
                slashes = 0;
            }
            sb.Append('\\', slashes * 2);
            sb.Append('"');
            return sb.ToString();
        }
    }
}
