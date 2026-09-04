using System.IO;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 字幕翻译 + 本地转写(<c>UI_PC.md</c> §7.15)。
///
/// <para>引擎的「配好了没」由<b>核心层</b>算(<c>translate.translationEngineStatus</c>),
/// UI 不自己判。自己判的后果是加一家新引擎、或者某家的必填项变了,状态点还按老规则亮着
/// —— 用户看到绿点、点下去打不通。</para>
///
/// <para>各家引擎的凭据字段形状不同,所以<b>按选中的那家画</b>,不是把五家的输入框
/// 全铺出来。全铺的话一屏十几个框,用户不知道该填哪几个。</para>
/// </summary>
public static class SettingsTranslate
{
    private static readonly (string Key, string Label)[] Engines =
    [
        ("openai", "AI · OpenAI 格式"), ("anthropic", "AI · Anthropic 格式"),
        ("baiduGeneral", "百度通用翻译"), ("baiduLlm", "百度大模型翻译"),
        ("tencent", "腾讯机器翻译"),
    ];

    private static readonly (string Key, string Label)[] Layouts =
    [
        ("translatedFirst", "译文在上,原文在下"), ("originalFirst", "原文在上,译文在下"),
        ("translatedOnly", "只显示译文"),
    ];

    public static Control Section(CoreClient core, JsonElement s)
    {
        var hint = Hint();

        var engine = Picker(Engines, Str(s, "engine"));
        var layout = Picker(Layouts, Str(s, "layout"));
        var target = new TextBox { Classes = { "field" }, Width = 120, Text = Str(s, "targetLang") };

        // 当前引擎的凭据字段。key = "组名/字段名"。
        var creds = new StackPanel { Spacing = 10 };
        var fields = new Dictionary<string, TextBox>();

        void Cred(string label, string group, string key, string watermark = "")
        {
            var sub = s.TryGetProperty(group, out var g) ? g : default;
            var box = new TextBox
            {
                Classes = { "field" }, Width = 320, Watermark = watermark, Text = Str(sub, key),
            };
            fields[group + "/" + key] = box;
            creds.Children.Add(Field(label, box));
        }

        void RebuildCreds()
        {
            creds.Children.Clear();
            fields.Clear();
            switch (Selected(engine))
            {
                case "anthropic":
                    Cred("接口地址", "anthropic", "baseUrl");
                    Cred("API Key", "anthropic", "apiKey");
                    Cred("模型", "anthropic", "model");
                    break;
                case "baiduGeneral":
                    Cred("APP ID", "baiduGeneral", "appId");
                    Cred("密钥", "baiduGeneral", "secretKey");
                    break;
                case "baiduLlm":
                    Cred("APP ID", "baiduLlm", "appId");
                    Cred("API Key", "baiduLlm", "apiKey", "推荐;留空则用下面的密钥签名");
                    Cred("密钥", "baiduLlm", "secretKey");
                    break;
                case "tencent":
                    Cred("SecretId", "tencent", "secretId");
                    Cred("SecretKey", "tencent", "secretKey");
                    Cred("地域", "tencent", "region");
                    break;
                default:
                    Cred("接口地址", "openai", "baseUrl");
                    Cred("API Key", "openai", "apiKey");
                    Cred("模型", "openai", "model");
                    break;
            }
        }
        engine.SelectionChanged += (_, _) => RebuildCreds();
        RebuildCreds();

        var status = Hint();
        async Task RefreshStatus()
        {
            try
            {
                var r = await core.TranslateTranslationEngineStatus();
                status.Text = string.Join("   ",
                    Engines.Select(e => (Bool(r, e.Key) ? "✓ " : "○ ") + e.Label));
            }
            catch (Exception e) { status.Text = LibraryPage.Advice(e); }
        }
        _ = RefreshStatus();

        var save = new Button { Content = "保存", MinHeight = 34 };
        save.Click += async (_, _) =>
        {
            try
            {
                var payload = new Dictionary<string, object?>
                {
                    ["engine"] = Selected(engine),
                    ["targetLang"] = (target.Text ?? "").Trim(),
                    ["layout"] = Selected(layout),
                };
                foreach (var kv in fields)
                {
                    var parts = kv.Key.Split('/');
                    if (payload.GetValueOrDefault(parts[0]) is not Dictionary<string, object?> g)
                    {
                        g = [];
                        payload[parts[0]] = g;
                    }
                    g[parts[1]] = kv.Value.Text ?? "";
                }
                await core.PrefsSetTranslationSettings(new { settings = payload });
                hint.Text = "已保存。";
                await RefreshStatus();
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        return Group("字幕翻译", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Field("引擎", engine),
                status,
                creds,
                Field("目标语言", target),
                Field("双语排版", layout),
                save, hint,
                Note("⚠ API Key 明文存在数据目录的 translation.json 里,和服务器令牌同等姿态。"),
            },
        });
    }

    /// <summary>拉不到设置时的那一组。**必须出现** —— 不出现的话用户会以为没这个功能。</summary>
    public static Control Unavailable(string why) => Group("字幕翻译", new StackPanel
    {
        Spacing = 10,
        Children =
        {
            Hint2("读不到翻译设置:" + (why == "" ? "(核心层没给原因)" : why)),
            Note("这一组的开关都在核心层的 prefs.getTranslationSettings 上,拉不到就没法画。"),
        },
    });

    private static TextBlock Hint2(string t)
    {
        var b = Hint();
        b.Text = t;
        return b;
    }

    /// <summary>本地转写(Whisper)。模型和依赖各自一块,单独成组。</summary>
    public static Control Whisper(CoreClient core)
    {
        var hint = Hint();
        var models = new StackPanel { Spacing = 6 };

        var getFfmpeg = new Button { Classes = { "ghost" }, Content = "自动下载 ffmpeg" };

        async Task Refresh()
        {
            try
            {
                var deps = await core.TranslateWhisperDeps(new { });
                var w = Str(deps, "whisper");
                var f = Str(deps, "ffmpeg");
                /* 两个依赖要**分开说**。合成一句「依赖未就绪」的话用户不知道
                   该去装哪个 —— 而这两件事的处置完全不同:ffmpeg 应用能自己下,
                   whisper-cli 不能(得用户自己装或手填路径)。 */
                hint.Text =
                    (w == "" ? "whisper-cli:未找到 —— 请自行安装,或在下面填绝对路径" : "whisper-cli:" + w)
                    + "\n" +
                    (f == "" ? "ffmpeg:未找到 —— 可以点下面的按钮自动下载" : "ffmpeg:" + f);
                getFfmpeg.IsVisible = f == "";

                var list = await core.TranslateWhisperModels(new { });
                models.Children.Clear();
                if (list.ValueKind != JsonValueKind.Array) return;
                foreach (var m in list.EnumerateArray())
                {
                    var key = Str(m, "key");
                    var downloaded = Bool(m, "downloaded");
                    var btn = new Button
                    {
                        Classes = { "ghost" }, MinHeight = 30,
                        Content = downloaded ? "删除" : "下载",
                    };
                    btn.Click += async (_, _) =>
                    {
                        // 模型 1~3GB:按钮必须当场变字并禁用,否则用户会反复点。
                        btn.IsEnabled = false;
                        btn.Content = downloaded ? "删除中…" : "下载中…";
                        try
                        {
                            if (downloaded) await core.TranslateWhisperDelete(new { model = key });
                            else await core.TranslateWhisperDownload(new { model = key });
                            await Refresh();
                        }
                        catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
                        finally { btn.IsEnabled = true; }
                    };
                    models.Children.Add(new StackPanel
                    {
                        Orientation = Orientation.Horizontal, Spacing = 10,
                        Children =
                        {
                            new TextBlock
                            {
                                Text = Str(m, "display_name"), Width = 240,
                                VerticalAlignment = VerticalAlignment.Center,
                            },
                            new TextBlock
                            {
                                Text = Str(m, "size_label"), Width = 90, Classes = { "dim" },
                                VerticalAlignment = VerticalAlignment.Center,
                            },
                            btn,
                        },
                    });
                }
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        }

        getFfmpeg.Click += async (_, _) =>
        {
            getFfmpeg.IsEnabled = false;
            getFfmpeg.Content = "下载中…";
            try
            {
                await core.TranslateWhisperDownloadFfmpeg(new { });
                await Refresh();
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
            finally { getFfmpeg.IsEnabled = true; getFfmpeg.Content = "自动下载 ffmpeg"; }
        };

        _ = Refresh();

        return Group("本地转写(Whisper)", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                hint,
                models,
                getFfmpeg,
                Note("模型几百 MB 到 3 GB,放在数据目录的 models/ 下 —— 清缓存不会删它。"),
            },
        });
    }

    // ---------------------------------------------------------------- 小工具

    /// <summary>
    /// 定位结果的人话。
    ///
    /// <para>核心层在 PATH 上找到时返回的是**裸文件名**(ffmpeg.exe)。
    /// 原样显示的话看着像一个相对路径,用户会以为它在程序目录里找到了 ——
    /// 于是去那个目录找,什么都没有。</para>
    /// </summary>
    private static string Where(string p) =>
        p.Contains(Path.DirectorySeparatorChar) || p.Contains('/') ? p : p + "(在系统 PATH 上)";

    private static ComboBox Picker((string Key, string Label)[] items, string cur)
    {
        var box = new ComboBox { Width = 210, MinHeight = 34 };
        foreach (var it in items) box.Items.Add(new ComboBoxItem { Content = it.Label, Tag = it.Key });
        var i = Array.FindIndex(items, e => e.Key == cur);
        box.SelectedIndex = i < 0 ? 0 : i;
        return box;
    }

    private static string Selected(ComboBox box) =>
        (box.SelectedItem as ComboBoxItem)?.Tag as string ?? "";

    private static Control Group(string title, Control body) => new Border
    {
        Classes = { "card" }, Padding = new Thickness(18, 18),
        HorizontalAlignment = HorizontalAlignment.Stretch,
        Child = new StackPanel
        {
            Spacing = 10,
            Children = { new TextBlock { Text = title, Classes = { "h2" } }, body },
        },
    };

    /// <summary>一行「说明 + 控件」。 标签右对齐、列宽 88 —— 三处 Field 必须一致,
    /// 口径见 <see cref="SettingsPage"/> 里那一份的注释。</summary>
    private static Control Field(string label, Control input) => new StackPanel
    {
        Orientation = Orientation.Horizontal, Spacing = 10,
        Children =
        {
            new TextBlock
            {
                Text = label, Width = 88, TextAlignment = TextAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
            },
            input,
        },
    };

    private static TextBlock Hint() => new()
    {
        Classes = { "dim" }, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap,
    };

    private static TextBlock Note(string t) => new()
    {
        Text = t, FontSize = 12, TextWrapping = TextWrapping.Wrap,
        Foreground = Tok.Of("Ink3"),
    };

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";

    private static bool Bool(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
}
