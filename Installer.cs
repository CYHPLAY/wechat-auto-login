using System;
using System.IO;
using System.Diagnostics;
using System.Reflection;
using System.Text;

internal static class WeChatAutoLoginInstaller
{
    // 内嵌资源逻辑名 -> 释放后的真实文件名
    private static readonly string[][] Files =
    {
        new string[]{ "wcal.setup",             "setup.ps1" },
        new string[]{ "wcal.wechat_autologin",  "wechat_autologin.ps1" },
        new string[]{ "wcal.wechat_common",     "wechat_common.ps1" },
        new string[]{ "wcal.install_autostart", "install_autostart.ps1" },
        new string[]{ "wcal.uninstall",         "uninstall.ps1" },
        new string[]{ "wcal.readme",            "README.md" }
    };

    private static int Main(string[] args)
    {
        bool silent = HasArg(args, "-silent") || Console.IsInputRedirected;
        try { Console.OutputEncoding = Encoding.UTF8; } catch { }
        Console.Title = "WeChat AutoLogin Setup";
        Console.WriteLine("==================================================");
        Console.WriteLine("   微信开机自动登录 - 一键安装");
        Console.WriteLine("==================================================");
        Console.WriteLine();

        string windir = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string powershell = Path.Combine(windir, @"System32\WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(powershell))
        {
            string sys = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string alt = Path.Combine(sys, @"WindowsPowerShell\v1.0\powershell.exe");
            if (File.Exists(alt)) powershell = alt;
        }
        if (!File.Exists(powershell)) { Fail("未找到 Windows PowerShell。"); return Pause(2, silent); }

        string srcDir = Path.Combine(Path.GetTempPath(),
            "WeChatAutoLogin_installer_" + Guid.NewGuid().ToString("N").Substring(0, 8));
        Directory.CreateDirectory(srcDir);

        int code;
        try
        {
            // 1) 释放内嵌脚本到临时目录
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

            // 2) 调用 setup.ps1 安装到当前用户目录
            string appDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "WeChatAutoLogin", "app");
            string setup = Path.Combine(srcDir, "setup.ps1");

            Console.WriteLine("安装目录: " + appDir);
            Console.WriteLine();

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = powershell;
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + setup +
                           "\" -SetupDir \"" + appDir + "\"";
            psi.WorkingDirectory = srcDir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = false;
            Process p = Process.Start(psi);
            p.WaitForExit();
            code = p.ExitCode;
            Console.WriteLine();

            if (code == 0)
            {
                Console.ForegroundColor = ConsoleColor.Green;
                Console.WriteLine("[成功] 已安装。下次开机登录 Windows 将自动启动并登录微信。");
                Console.ResetColor();
                Console.WriteLine("如需立即测试，可运行: Start-ScheduledTask -TaskName 'WeChatAutoLogin'");
            }
            else
            {
                Fail("安装脚本退出码为 " + code + "，请把上方信息反馈。");
            }
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
        return Pause(code, silent);
    }

    private static bool HasArg(string[] args, string name)
    {
        if (args == null) return false;
        foreach (string a in args) if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static int Pause(int code, bool silent)
    {
        if (!silent)
        {
            Console.WriteLine();
            Console.WriteLine("按任意键退出...");
            try { Console.ReadKey(true); } catch { }
        }
        return code;
    }

    private static void Fail(string msg)
    {
        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine("[错误] " + msg);
        Console.ResetColor();
    }
}
