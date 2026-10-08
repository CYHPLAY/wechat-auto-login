using System;
using System.IO;
using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Collections.Generic;

internal static class WeChatAutoLoginInstaller
{
    // Logical resource name -> file released into the temporary directory.
    private static readonly string[][] Files =
    {
        new string[]{ "wcal.manager",           "manager.ps1" },
        new string[]{ "wcal.setup",             "setup.ps1" },
        new string[]{ "wcal.wechat_autologin",  "wechat_autologin.ps1" },
        new string[]{ "wcal.wechat_common",     "wechat_common.ps1" },
        new string[]{ "wcal.install_autostart", "install_autostart.ps1" },
        new string[]{ "wcal.uninstall",         "uninstall.ps1" },
        new string[]{ "wcal.readme",            "README.md" }
    };

    private static int Main(string[] args)
    {
        bool silent = HasFlag(args, "silent");
        try { Console.OutputEncoding = Encoding.UTF8; } catch { }
        Console.Title = "WeChat AutoLogin";
        Console.WriteLine("==================================================");
        Console.WriteLine("   微信开机自动登录");
        Console.WriteLine("   开机自动打开微信并进入主界面");
        Console.WriteLine("   开源: https://github.com/CYHPLAY/wechat-auto-login");
        Console.WriteLine("==================================================");

        string windir = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string powershell = Path.Combine(windir, @"System32\WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(powershell))
        {
            string alt = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (File.Exists(alt)) powershell = alt;
        }
        if (!File.Exists(powershell)) { Fail("未找到 Windows PowerShell。"); return Pause(2, silent); }

        string srcDir = Path.Combine(Path.GetTempPath(),
            "WeChatAutoLogin_installer_" + Guid.NewGuid().ToString("N").Substring(0, 8));
        Directory.CreateDirectory(srcDir);
        int code;
        try
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            foreach (string[] f in Files)
            {
                using (Stream rs = asm.GetManifestResourceStream(f[0]))
                {
                    if (rs == null) { Fail("缺少内嵌文件: " + f[0]); return Pause(3, silent); }
                    using (FileStream fs = File.Create(Path.Combine(srcDir, f[1])))
                        rs.CopyTo(fs);
                }
            }

            // No arguments: enter the interactive manager menu. Otherwise forward
            // install/test/uninstall/status and -silent to manager.ps1.
            string manager = Path.Combine(srcDir, "manager.ps1");
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = powershell;
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + manager + "\"" + ForwardArgs(args);
            psi.WorkingDirectory = srcDir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = false;
            Process p = Process.Start(psi);
            p.WaitForExit();
            code = p.ExitCode;
        }
        catch (Exception ex)
        {
            Fail("发生异常: " + ex.Message);
            code = 4;
        }
        finally
        {
            try { Directory.Delete(srcDir, true); } catch { }
        }
        return code;
    }

    // Accept both "-Action install" and a bare "install"; any form of -silent.
    // Value options such as -WeChatExe keep their following value; everything else passes through.
    private static string ForwardArgs(string[] args)
    {
        StringBuilder sb = new StringBuilder();
        bool silent = false;
        HashSet<string> actions = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "install", "test", "uninstall", "status", "menu" };
        HashSet<string> valueOptions = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "wechatexe", "setupdir" };

        if (args != null)
        {
            for (int i = 0; i < args.Length; i++)
            {
                string a = (args[i] ?? "").Trim();
                if (a.Length == 0) continue;
                string key = a.TrimStart('-', '/').ToLowerInvariant();
                bool bare = !a.StartsWith("-") && !a.StartsWith("/");

                if (key == "silent") { silent = true; continue; }

                if (key == "action")
                {
                    string val = null;
                    int eq = a.IndexOf('=');
                    if (eq >= 0) val = a.Substring(eq + 1).Trim().Trim('"');
                    else if (i + 1 < args.Length) val = (args[++i] ?? "").Trim().Trim('"');
                    if (!string.IsNullOrEmpty(val))
                    {
                        string vk = val.TrimStart('-', '/').ToLowerInvariant();
                        if (actions.Contains(vk)) sb.Append(" -Action ").Append(Capitalize(vk));
                        else sb.Append(" -Action \"").Append(val).Append("\"");
                    }
                    continue;
                }

                if (bare && actions.Contains(key)) { sb.Append(" -Action ").Append(Capitalize(key)); continue; }

                if (!bare && valueOptions.Contains(key))
                {
                    sb.Append(' ').Append(a);
                    int eq = a.IndexOf('=');
                    if (eq < 0 && i + 1 < args.Length) sb.Append(' ').Append(QuoteIfNeeded(args[++i]));
                    continue;
                }

                sb.Append(' ').Append(a);
            }
        }
        if (silent) sb.Append(" -Silent");
        return sb.ToString();
    }

    private static string Capitalize(string s)
    {
        if (string.IsNullOrEmpty(s)) return s;
        return char.ToUpper(s[0]) + s.Substring(1);
    }

    private static string QuoteIfNeeded(string v)
    {
        v = v ?? "";
        if (v.Length == 0) return "\"\"";
        if (v.IndexOf(' ') >= 0 && v[0] != '"') return "\"" + v + "\"";
        return v;
    }

    private static bool HasFlag(string[] args, string name)
    {
        if (args == null) return false;
        foreach (string a in args)
            if (a != null && a.TrimStart('-', '/').Equals(name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static int Pause(int code, bool silent)
    {
        if (!silent) { Console.WriteLine("按任意键退出..."); try { Console.ReadKey(true); } catch { } }
        return code;
    }

    private static void Fail(string msg)
    {
        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine("[错误] " + msg);
        Console.ResetColor();
    }
}
