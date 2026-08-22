using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal sealed class CodexRemoteTray : ApplicationContext
{
    private sealed class OwnedProcess
    {
        public Process Process;
        public string Role;
        public volatile bool ExpectedExit;
    }

    private readonly NotifyIcon tray;
    private readonly ToolStripMenuItem statusItem;
    private readonly ToolStripMenuItem enableItem;
    private readonly ToolStripMenuItem pairItem;
    private readonly ToolStripMenuItem disableItem;
    private readonly string root;
    private readonly JavaScriptSerializer json = new JavaScriptSerializer();
    private readonly object ownedSync = new object();
    private readonly List<OwnedProcess> owned = new List<OwnedProcess>();
    private volatile bool busy;
    private volatile bool supervisionActive;
    private volatile bool supervisionFailureHandling;
    private string mobileUrl;
    private string pairingCode;

    private CodexRemoteTray()
    {
        root = ResolveAppRoot();
        tray = new NotifyIcon { Icon = SystemIcons.Shield, Text = "Codex Remote Approvals", Visible = true };
        var menu = new ContextMenuStrip();
        statusItem = new ToolStripMenuItem("Remote approvals are off") { Enabled = false };
        enableItem = new ToolStripMenuItem("Enable Remote Approvals", null, delegate { EnableAsync(); });
        pairItem = new ToolStripMenuItem("Pair Phone", null, delegate { ShowPairing(); }) { Enabled = false };
        disableItem = new ToolStripMenuItem("Disable Remote Approvals", null, delegate { Disable(); }) { Enabled = false };
        var exit = new ToolStripMenuItem("Exit", null, delegate { ExitTray(); });
        menu.Items.Add(statusItem); menu.Items.Add(new ToolStripSeparator()); menu.Items.Add(enableItem);
        menu.Items.Add(pairItem); menu.Items.Add(disableItem); menu.Items.Add(new ToolStripSeparator()); menu.Items.Add(exit);
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += delegate { if (pairItem.Enabled) ShowPairing(); else EnableAsync(); };
    }

    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new CodexRemoteTray());
    }

    private static string ResolveAppRoot()
    {
        string here = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        if (Directory.Exists(Path.Combine(here, "companion-build"))) return here;
        DirectoryInfo parent = Directory.GetParent(here);
        if (parent != null && Directory.Exists(Path.Combine(parent.FullName, "companion-build"))) return parent.FullName;
        return here;
    }

    private void EnableAsync()
    {
        lock (ownedSync)
        {
            if (busy || owned.Count > 0) return;
        }
        busy = true; enableItem.Enabled = false; statusItem.Text = "Starting remote approvals...";
        ThreadPool.QueueUserWorkItem(delegate
        {
            try
            {
                supervisionActive = false;
                supervisionFailureHandling = false;
                StartStack();
                supervisionActive = true;
                Ui(delegate
                {
                    statusItem.Text = "Remote approvals are on";
                    pairItem.Enabled = true; disableItem.Enabled = true;
                    tray.ShowBalloonTip(3000, "Codex Remote Approvals", "Remote approvals are ready. Pair your phone to continue.", ToolTipIcon.Info);
                    ShowPairing();
                });
            }
            catch (Exception ex)
            {
                supervisionActive = false;
                StopOwned();
                Ui(delegate
                {
                    mobileUrl = null; pairingCode = null;
                    statusItem.Text = "Remote approvals are off";
                    enableItem.Enabled = true; pairItem.Enabled = false; disableItem.Enabled = false;
                    MessageBox.Show(Friendly(ex.Message), "Could not start remote approvals", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                });
            }
            finally { busy = false; }
        });
    }

    private void StartStack()
    {
        RequireFile("companion-build\\CodexLocalCompanion.exe");
        RequireFile("gateway-build\\CodexLanGateway.exe");
        RequireFile("mobile-build\\CodexMobileUiServer.exe");
        RequireFile("Select-CodexLiveThread.ps1");
        RequireDirectory("mobile");

        string bridge = FindLiveDescriptor(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexApprovalNotifier", "local-bridge"), "bridge-*.json", "shimPid", "codexPid");
        string thread = SelectThread(bridge);
        string ip = FindHomeIpv4();

        string companionExe = Path.Combine(root, "companion-build", "CodexLocalCompanion.exe");
        OwnedProcess companionProcess = StartOwned(companionExe, "--descriptor " + Q(bridge) + " --thread " + Q(thread) + " --port 8765", false, "companion");
        string companion = WaitOwnedDescriptor("companion", "companion-", companionProcess, 10000);

        string gatewayExe = Path.Combine(root, "gateway-build", "CodexLanGateway.exe");
        OwnedProcess gateway = StartOwned(gatewayExe, "--companion-descriptor " + Q(companion) + " --listen-address " + ip + " --port 8766", true, "LAN gateway");
        pairingCode = ReadLineValue(gateway.Process, "Pairing code:", 10000);
        string gatewayDescriptor = WaitOwnedDescriptor("lan-gateway", "gateway-", gateway, 10000);
        var gd = ReadJson(gatewayDescriptor);
        string gatewayUrl = Convert.ToString(gd["api"]);

        string mobileExe = Path.Combine(root, "mobile-build", "CodexMobileUiServer.exe");
        mobileUrl = "http://" + ip + ":8767/";
        StartOwned(mobileExe, "--listen-address " + ip + " --port 8767 --gateway-base " + Q(gatewayUrl) + " --web-root " + Q(Path.Combine(root, "mobile")), false, "mobile UI");
        WaitHttp(mobileUrl, 10000);
    }

    private string SelectThread(string bridge)
    {
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(ps)) throw new InvalidOperationException("Windows PowerShell is unavailable.");
        var p = new Process();
        p.StartInfo = new ProcessStartInfo
        {
            FileName = ps,
            Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File " + Q(Path.Combine(root, "Select-CodexLiveThread.ps1")) + " -DescriptorPath " + Q(bridge),
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        p.Start();
        string output = p.StandardOutput.ReadToEnd().Trim(); string error = p.StandardError.ReadToEnd().Trim(); p.WaitForExit();
        if (p.ExitCode != 0 || String.IsNullOrWhiteSpace(output)) throw new InvalidOperationException(String.IsNullOrWhiteSpace(error) ? "No active Codex chat could be selected." : error);
        string line = output.Split(new[] {'\r','\n'}, StringSplitOptions.RemoveEmptyEntries).Last().Trim();
        Guid parsed; if (!Guid.TryParse(line, out parsed)) throw new InvalidOperationException("Codex returned an unexpected live-thread identifier.");
        return line;
    }

    private string FindHomeIpv4()
    {
        var candidates = new List<string>();
        foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            IPInterfaceProperties props; try { props = nic.GetIPProperties(); } catch { continue; }
            bool gateway = props.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.Any.Equals(g.Address));
            if (!gateway) continue;
            foreach (UnicastIPAddressInformation u in props.UnicastAddresses)
                if (u.Address.AddressFamily == AddressFamily.InterNetwork && IsPrivate(u.Address)) candidates.Add(u.Address.ToString());
        }
        candidates = candidates.Distinct().ToList();
        if (candidates.Count == 0) throw new InvalidOperationException("No private home-network IPv4 address was found. Connect this PC to your home Wi-Fi or Ethernet and try again.");
        if (candidates.Count > 1) throw new InvalidOperationException("More than one active private network was found. Disconnect VPNs or extra network adapters and try again.");
        return candidates[0];
    }

    private static bool IsPrivate(IPAddress a)
    {
        byte[] b = a.GetAddressBytes();
        return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
    }

    private OwnedProcess StartOwned(string file, string args, bool captureOutput, string role)
    {
        var p = new Process();
        p.StartInfo = new ProcessStartInfo { FileName=file, Arguments=args, WorkingDirectory=root, UseShellExecute=false, CreateNoWindow=true,
            RedirectStandardOutput=captureOutput, RedirectStandardError=captureOutput };
        var entry = new OwnedProcess { Process = p, Role = role, ExpectedExit = false };
        p.EnableRaisingEvents = true;
        p.Exited += delegate { OnOwnedProcessExited(entry); };
        if (!p.Start())
        {
            p.Dispose();
            throw new InvalidOperationException("A remote-approval component could not be started.");
        }
        lock (ownedSync) { owned.Add(entry); }
        return entry;
    }

    private void OnOwnedProcessExited(OwnedProcess entry)
    {
        if (entry == null || entry.ExpectedExit || !supervisionActive) return;
        lock (ownedSync)
        {
            if (entry.ExpectedExit || !supervisionActive || supervisionFailureHandling) return;
            supervisionFailureHandling = true;
            supervisionActive = false;
        }

        ThreadPool.QueueUserWorkItem(delegate
        {
            try { StopOwned(); }
            finally
            {
                mobileUrl = null; pairingCode = null;
                Ui(delegate
                {
                    statusItem.Text = "Remote approvals stopped: " + entry.Role + " exited";
                    enableItem.Enabled = true; pairItem.Enabled = false; disableItem.Enabled = false;
                    tray.ShowBalloonTip(3500, "Codex Remote Approvals", "Remote approvals stopped because the " + entry.Role + " process exited.", ToolTipIcon.Warning);
                });
            }
        });
    }

    private string ReadLineValue(Process p, string prefix, int timeoutMs)
    {
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            if (p.HasExited) throw new InvalidOperationException(ReadStartupFailure(p, "The LAN gateway stopped while starting."));
            int remaining = Math.Max(1, (int)(deadline - DateTime.UtcNow).TotalMilliseconds);
            var task = p.StandardOutput.ReadLineAsync();
            if (!task.Wait(remaining)) throw new InvalidOperationException("The LAN gateway did not provide a pairing code.");
            string line = task.Result;
            if (line == null)
            {
                if (p.HasExited) throw new InvalidOperationException(ReadStartupFailure(p, "The LAN gateway stopped while starting."));
                break;
            }
            if (line.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return line.Substring(prefix.Length).Trim();
        }
        throw new InvalidOperationException("The LAN gateway did not provide a pairing code.");
    }

    private string ReadStartupFailure(Process p, string fallback)
    {
        try
        {
            if (p.StartInfo.RedirectStandardError && p.HasExited)
            {
                string detail = p.StandardError.ReadToEnd().Trim();
                if (!String.IsNullOrWhiteSpace(detail)) return detail;
            }
        }
        catch { }
        return fallback;
    }

    private string WaitOwnedDescriptor(string folder, string prefix, OwnedProcess owner, int timeoutMs)
    {
        string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexApprovalNotifier", folder);
        int pid = owner.Process.Id;
        string expected = Path.Combine(dir, prefix + pid + ".json");
        DateTime startedUtc = owner.Process.StartTime.ToUniversalTime();
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);

        while (DateTime.UtcNow < deadline)
        {
            if (owner.Process.HasExited)
                throw new InvalidOperationException(owner.Role + " stopped while starting.");

            if (File.Exists(expected))
            {
                try
                {
                    if (File.GetLastWriteTimeUtc(expected) < startedUtc)
                    {
                        Thread.Sleep(50);
                        continue;
                    }

                    var d = ReadJson(expected);
                    int descriptorPid = Convert.ToInt32(d["pid"]);
                    if (descriptorPid != pid)
                    {
                        Thread.Sleep(50);
                        continue;
                    }

                    object createdValue;
                    if (d.TryGetValue("createdAt", out createdValue) && createdValue != null)
                    {
                        DateTimeOffset createdAt = DateTimeOffset.Parse(Convert.ToString(createdValue), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
                        if (createdAt.UtcDateTime < startedUtc)
                        {
                            Thread.Sleep(50);
                            continue;
                        }
                    }

                    return expected;
                }
                catch
                {
                    if (owner.Process.HasExited)
                        throw new InvalidOperationException(owner.Role + " stopped while starting.");
                }
            }
            Thread.Sleep(100);
        }
        throw new InvalidOperationException("The " + owner.Role + " did not publish its current runtime descriptor.");
    }

    private string FindLiveDescriptor(string dir, string pattern, string firstPid, string secondPid)
    {
        if (!Directory.Exists(dir)) throw new InvalidOperationException("Open VS Code and a Codex chat first.");
        foreach (string f in Directory.GetFiles(dir, pattern).OrderByDescending(File.GetLastWriteTimeUtc))
        {
            try
            {
                var d = ReadJson(f);
                int first = Convert.ToInt32(d[firstPid]);
                int second = Convert.ToInt32(d[secondPid]);
                object createdValue;
                if (!d.TryGetValue("createdAt", out createdValue) || createdValue == null) continue;
                DateTimeOffset createdAt = DateTimeOffset.Parse(Convert.ToString(createdValue), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
                Process firstProcess = Process.GetProcessById(first);
                Process secondProcess = Process.GetProcessById(second);
                if (firstProcess.StartTime.ToUniversalTime() > createdAt.UtcDateTime) continue;
                if (secondProcess.StartTime.ToUniversalTime() > createdAt.UtcDateTime) continue;
                return f;
            }
            catch { }
        }
        throw new InvalidOperationException("Remote approvals are not connected to VS Code yet. Open VS Code and a Codex chat first.");
    }

    private Dictionary<string,object> ReadJson(string path)
    {
        var d = json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string,object>;
        if (d == null) throw new InvalidDataException("Invalid runtime descriptor."); return d;
    }

    private void WaitHttp(string url, int timeoutMs)
    {
        DateTime deadline=DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while(DateTime.UtcNow<deadline)
        {
            try { var r=(HttpWebRequest)WebRequest.Create(url); r.Timeout=1000; r.KeepAlive=false; using((HttpWebResponse)r.GetResponse()) return; }
            catch { Thread.Sleep(150); }
        }
        throw new InvalidOperationException("The phone page did not finish starting.");
    }

    private void ShowPairing()
    {
        if (String.IsNullOrWhiteSpace(mobileUrl) || String.IsNullOrWhiteSpace(pairingCode)) return;
        string qrUrl = mobileUrl + "#pair=" + pairingCode;
        using (Bitmap qr = QrCodeV4.Render(qrUrl, 7))
        using (var form = new Form { Text="Pair your phone", StartPosition=FormStartPosition.CenterScreen, ClientSize=new Size(520,535), FormBorderStyle=FormBorderStyle.FixedDialog, MaximizeBox=false, MinimizeBox=false, TopMost=true })
        {
            var title = new Label { Text="Connect your phone", Font=new Font(SystemFonts.MessageBoxFont.FontFamily,17,FontStyle.Bold), AutoSize=true, Location=new Point(24,18) };
            var help = new Label { Text="Scan this QR code with your iPhone camera. Safari will open and pair automatically.", AutoSize=false, Size=new Size(470,42), Location=new Point(24,56), TextAlign=ContentAlignment.MiddleCenter };
            var picture = new PictureBox { Image=qr, SizeMode=PictureBoxSizeMode.CenterImage, Location=new Point(116,100), Size=new Size(287,287), BackColor=Color.White };
            var fallback = new Label { Text="If scanning does not work, use the address and code below.", AutoSize=true, Location=new Point(24,402) };
            var url = new TextBox { Text=mobileUrl, ReadOnly=true, Location=new Point(24,429), Width=330 };
            var copyUrl = new Button { Text="Copy address", Location=new Point(360,427), Width=110 }; copyUrl.Click += delegate { Clipboard.SetText(mobileUrl); };
            var codeLabel = new Label { Text="Pairing code", AutoSize=true, Location=new Point(24,471) };
            var code = new TextBox { Text=pairingCode, ReadOnly=true, Font=new Font(FontFamily.GenericMonospace,14,FontStyle.Bold), Location=new Point(125,463), Width=120, TextAlign=HorizontalAlignment.Center };
            var copyCode = new Button { Text="Copy code", Location=new Point(255,461), Width=100 }; copyCode.Click += delegate { Clipboard.SetText(pairingCode); };
            var close = new Button { Text="Done", DialogResult=DialogResult.OK, Location=new Point(390,493), Width=80 };
            form.Controls.AddRange(new Control[] { title,help,picture,fallback,url,copyUrl,codeLabel,code,copyCode,close });
            form.AcceptButton=close;
            form.ShowDialog();
        }
    }

    private void Disable()
    {
        if (busy) return;
        supervisionActive = false;
        StopOwned(); mobileUrl=null; pairingCode=null;
        statusItem.Text="Remote approvals are off"; enableItem.Enabled=true; pairItem.Enabled=false; disableItem.Enabled=false;
        tray.ShowBalloonTip(2000,"Codex Remote Approvals","Remote approvals were stopped.",ToolTipIcon.Info);
    }

    private void StopOwned()
    {
        List<OwnedProcess> snapshot;
        lock (ownedSync)
        {
            snapshot = new List<OwnedProcess>(owned);
            foreach (OwnedProcess entry in snapshot) entry.ExpectedExit = true;
            owned.Clear();
        }
        for(int i=snapshot.Count-1;i>=0;i--)
        {
            Process p = snapshot[i].Process;
            try{if(!p.HasExited) p.Kill();}catch{}
            try{p.Dispose();}catch{}
        }
    }

    private void ExitTray(){supervisionActive=false;Disable();tray.Visible=false;tray.Dispose();ExitThread();}
    protected override void Dispose(bool disposing){if(disposing){supervisionActive=false;StopOwned();tray.Dispose();}base.Dispose(disposing);}
    private void Ui(MethodInvoker action){if(tray.ContextMenuStrip.InvokeRequired) tray.ContextMenuStrip.BeginInvoke(action); else action();}
    private void RequireFile(string rel){if(!File.Exists(Path.Combine(root,rel))) throw new InvalidOperationException("The app installation is incomplete. Missing " + rel + ".");}
    private void RequireDirectory(string rel){if(!Directory.Exists(Path.Combine(root,rel))) throw new InvalidOperationException("The app installation is incomplete. Missing " + rel + ".");}
    private static string Q(string s){return "\"" + s.Replace("\"","\\\"") + "\"";}
    private static string Friendly(string s){if(String.IsNullOrWhiteSpace(s)) return "Remote approvals could not be started."; return s.Replace("System.Management.Automation.RuntimeException: ","").Trim();}
}
