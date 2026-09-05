using System;
using System.IO;
using System.Text;

namespace LinPlayer.Desktop.Core;

/// <summary>
/// 壳自己的日志。三档:<c>warn</c> / <c>info</c> / <c>debug</c>,在设置页里切。
///
/// <para>存在的理由:有些现象<b>只在用户那台机器上出现</b>(2026-09-05 的「按钮会闪」
/// 就是 —— 我这边连拍、真指针悬停、属性翻转计数全试过,一次都没复现)。
/// 复现不了就只能把探针交到用户手上,而 <c>LP_*</c> 那些环境变量只有开发机会用。</para>
///
/// <para>默认 warn:日志本身不该成为负担。debug 是**用来抓现场**的,
/// 抓完切回去 —— 所以档位落盘,不跟着版本走。</para>
/// </summary>
public static class Log
{
    public enum Level
    {
        Warn = 0,
        Info = 1,
        Debug = 2,
    }

    private static readonly object Gate = new();
    private static string _file = "";
    private static string _levelFile = "";
    private static int _writes;

    /// <summary>当前档位。</summary>
    public static Level Current { get; private set; } = Level.Warn;

    /// <summary>debug 开着没有?**热路上要先判它再拼字符串** —— 拼了再丢等于白拼。</summary>
    public static bool DebugOn => Current >= Level.Debug;

    /// <summary>日志文件在哪。设置页要显示给用户看。</summary>
    public static string FilePath => _file;

    /// <summary>
    /// 在 <c>Program.Main</c> 里调一次。<paramref name="dataDir"/> 就是传给核心层的那个根 ——
    /// 这里不另拼一套路径策略(WebView2 profile 绕过 paths 那次的教训)。
    /// </summary>
    public static void Init(string dataDir)
    {
        try
        {
            var dir = Path.Combine(dataDir, "logs");
            Directory.CreateDirectory(dir);
            _file = Path.Combine(dir, "desktop.log");
            _levelFile = Path.Combine(dir, "level.txt");
            if (File.Exists(_levelFile) &&
                Enum.TryParse<Level>(File.ReadAllText(_levelFile).Trim(), true, out var l))
                Current = l;
            // 自检用的口子:环境变量压过落盘的档位(自检不该去改用户的配置)
            if (Enum.TryParse<Level>(Environment.GetEnvironmentVariable("LP_LOG"), true, out var el))
                Current = el;
            Trim();
            Write(Level.Warn, "启动", $"日志档位 {Current}");
        }
        catch
        {
            // 日志起不来不该拖垮启动。写不了就退化成「不写」,别在这儿抛。
            _file = "";
        }
    }

    /// <summary>切档位并落盘。设置页调它。</summary>
    public static void SetLevel(Level l)
    {
        Current = l;
        try
        {
            if (_levelFile != "") File.WriteAllText(_levelFile, l.ToString());
        }
        catch { /* 落盘失败只影响下次启动的默认值,本次已经生效了,不值得打断用户 */ }
        Write(Level.Warn, "设置", $"日志档位切到 {l}");
    }

    public static void W(string tag, string msg) => Write(Level.Warn, tag, msg);

    public static void I(string tag, string msg) => Write(Level.Info, tag, msg);

    /// <summary>debug 一条。**调用前先判 <see cref="DebugOn"/>**,别在热路上白拼字符串。</summary>
    public static void D(string tag, string msg) => Write(Level.Debug, tag, msg);

    private static void Write(Level l, string tag, string msg)
    {
        if (l > Current || _file == "") return;
        try
        {
            lock (Gate)
            {
                File.AppendAllText(_file,
                    $"{DateTime.Now:HH:mm:ss.fff} {l,-5} [{tag}] {msg}{Environment.NewLine}",
                    Encoding.UTF8);
                if (++_writes % 500 == 0) Trim();
            }
        }
        catch { /* 磁盘满 / 文件被占:丢掉这一条,不影响正在做的事 */ }
    }

    /// <summary>超过 8MB 就从头来。debug 档一场播放能写出几万行,不封顶会撑爆绿色包。</summary>
    private static void Trim()
    {
        try
        {
            if (_file != "" && new FileInfo(_file) is { Exists: true, Length: > 8 * 1024 * 1024 })
                File.WriteAllText(_file, "");
        }
        catch { /* 拿不到文件信息就不裁,下次再说 */ }
    }
}
