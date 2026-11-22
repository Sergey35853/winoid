using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
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
        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr h);
        private delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr h, StringBuilder s, int n);

        // The manager window is the only top-level WPF window titled exactly
        // "Winoid" (app wrappers are "<App> - Winoid", and a message box has
        // the #32770 class). Checking the class avoids restoring a dialog.
        private static IntPtr FindMainWindow() {
            IntPtr found = IntPtr.Zero;
            EnumWindows(delegate(IntPtr h, IntPtr l) {
                var text = new StringBuilder(256);
                GetWindowText(h, text, text.Capacity);
                if (text.ToString() != "Winoid") return true;
                var cls = new StringBuilder(256);
                GetClassName(h, cls, cls.Capacity);
                if (!cls.ToString().StartsWith("HwndWrapper")) return true;
                found = h;
                return false;
            }, IntPtr.Zero);
            return found;
        }

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

            // One watchdog per session. Without this a second shortcut click
            // started another watchdog; its manager exited at the manager's
            // single-instance mutex without writing shutdown.request, so the
            // watchdog restarted it every 2.5 s and re-queued -Launch each
            // time, which looked like the app launching itself over and over.
            var mutex = new Mutex(false, @"Local\WinoidLauncher");
            bool owned = false;
            try { owned = mutex.WaitOne(0); }
            catch (AbandonedMutexException) { owned = true; }
            if (!owned) {
                QueueRequest(data, args);
                IntPtr existing = FindMainWindow();
                if (existing != IntPtr.Zero) {
                    ShowWindow(existing, 9);
                    SetForegroundWindow(existing);
                }
                return;
            }

            try {
                Run(dir, script, data, shutdown, legacyQuit, args);
            } finally {
                try { mutex.ReleaseMutex(); } catch { }
                mutex.Dispose();
            }
        }

        private static void Run(string dir, string script, string data,
                                string shutdown, string legacyQuit, string[] args) {
            // Remember the original arguments for the very first start only.
            // A watchdog restart must not silently relaunch the game again.
            string[] firstArgs = args;
            bool first = true;
            int fastFailures = 0;

            for (;;) {
                try {
                    if (File.Exists(shutdown)) File.Delete(shutdown);
                    if (File.Exists(legacyQuit)) File.Delete(legacyQuit);
                } catch { }

                var sw = Stopwatch.StartNew();
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
                sw.Stop();
                proc.Dispose();
                first = false;

                bool clean = false;
                try { clean = File.Exists(shutdown) || File.Exists(legacyQuit); } catch { }
                Log(data, "manager exited; restart=" + !clean +
                    " after=" + (int)sw.Elapsed.TotalSeconds + "s");

                if (clean) break;

                // A manager that dies right after start (missing dependency,
                // parse error, broken backend) must not be restarted forever.
                if (sw.Elapsed.TotalSeconds < 10) fastFailures++; else fastFailures = 0;
                if (fastFailures >= 5) {
                    Log(data, "giving up after " + fastFailures + " quick failures");
                    MessageBox.Show(
                        "Winoid не удалось запустить: менеджер завершается сразу после старта.\n\n" +
                        "Подробности: " + Path.Combine(data, "winoid.log"),
                        "Winoid", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    break;
                }

                int delay = fastFailures == 0 ? 2500 : Math.Min(15000, 2500 * fastFailures);
                Thread.Sleep(delay);
            }
        }

        // A second launch carries -Launch/-Install. The manager that owns the
        // single-instance mutex reads the queue, so write the request here and
        // let the primary instance handle it.
        private static void QueueRequest(string data, string[] args) {
            string action = null;
            string target = null;
            for (int i = 0; i < args.Length; i++) {
                if (string.Equals(args[i], "-Launch", StringComparison.OrdinalIgnoreCase) &&
                    i + 1 < args.Length) {
                    action = "launch";
                    target = args[++i];
                } else if (string.Equals(args[i], "-Install", StringComparison.OrdinalIgnoreCase) &&
                           i + 1 < args.Length) {
                    action = "install";
                    target = args[++i];
                }
            }
            if (action == null || string.IsNullOrEmpty(target)) return;

            try {
                string queue = Path.Combine(data, "queue");
                Directory.CreateDirectory(queue);
                string name = "req-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") +
                    "-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".json";
                string json = "{\"action\":\"" + action + "\",\"target\":\"" +
                    JsonEscape(target) + "\",\"created\":\"" +
                    DateTime.Now.ToString("o") + "\"}";
                string tmp = Path.Combine(queue, name + ".tmp");
                File.WriteAllText(tmp, json, new UTF8Encoding(false));
                File.Move(tmp, Path.Combine(queue, name));
            } catch { }
        }

        private static string JsonEscape(string value) {
            var sb = new StringBuilder(value.Length + 8);
            foreach (char c in value) {
                switch (c) {
                    case '\\': sb.Append("\\\\"); break;
                    case '"': sb.Append("\\\""); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default: sb.Append(c); break;
                }
            }
            return sb.ToString();
        }

        private static void Log(string data, string message) {
            try {
                string log = Path.Combine(data, "launcher.log");
                var fi = new FileInfo(log);
                if (fi.Exists && fi.Length > 1048576) File.Delete(log);
                File.AppendAllText(log, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") +
                    " " + message + Environment.NewLine);
            } catch { }
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
