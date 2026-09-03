using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Threading;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 会虚拟化的媒体网格。
///
/// <para>★★ 原来是一个 <c>WrapPanel</c> 把所有条目一次性 new 成卡片。
/// 140 条时是 140 张卡 × 约 10 个可视元素 = 一千四百个控件要测量、排布、命中测试;
/// 而真实媒体库动辄上千条,滚到底就是上万个。**这不是「慢一点」,是量级问题**。</para>
///
/// <para>★ Avalonia 11 的基础包里<b>没有 ItemsRepeater / UniformGridLayout</b>
/// (那是另一个 NuGet 包),但有 <see cref="VirtualizingStackPanel"/> —— 它只虚拟化
/// <b>一维列表</b>。所以这里把网格<b>按行折</b>:数据是「一行若干张卡」,
/// 竖直方向交给它虚拟化。卡片宽高固定 = 行高一致,这正是它工作得最好的形状。</para>
///
/// <para>★ 列数<b>按实际宽度算</b>,窗口变了要重算。写死列数的话,
/// 侧栏收起、窗口最大化、4K 屏 —— 每一种都会留下一条空白或者切掉半张卡。</para>
///
/// <para>★★ <b>卡片跟着行宽伸缩,把这一行铺满</b>(用户 2026-09-03 第二次点名:
/// 「右边还是有留空,我不知道你留空的意义在哪」)。
/// 上一轮只去掉了 <c>MaxWidth=1560</c> 那道封顶,但卡片宽度是**写死的 158**——
/// 1400 宽的区域放得下 8 列(8×158 + 7×14 = 1362),<b>右边必然剩 38px</b>。
/// 那 38px 不是设计,是整除不尽的余数。现在反过来算:
/// 先按最小宽定列数,再把整行的宽度<b>均分给这几列</b>,余数一个像素都不剩。</para>
/// </summary>
public sealed class MediaGrid : ContentControl
{
    /// <summary>卡片之间的横纵间距。和原来 WrapPanel 时代的 Margin 一致,换过来不跳版。</summary>
    private const double Gap = 14;

    private readonly CoreClient _core;
    private readonly string _server;
    private readonly bool _wide, _episodeStyle;
    private readonly double? _width;
    /// <summary>标题区固定几行。库卡传 1(库名只有一行),条目卡默认 2。</summary>
    private readonly int _titleLines;
    private readonly Action<CardItem>? _onOpen;

    private readonly List<CardItem> _items = [];
    private readonly ItemsControl _list;
    private int _cols = -1;

    public MediaGrid(CoreClient core, string server, bool wide,
        Action<CardItem>? onOpen = null, bool episodeStyle = false, double? width = null,
        int titleLines = 2)
    {
        _core = core; _server = server; _wide = wide;
        _onOpen = onOpen; _episodeStyle = episodeStyle; _width = width; _titleLines = titleLines;

        _list = new ItemsControl
        {
            // ★ 这一行就是虚拟化的开关。不设的话默认是 StackPanel,全量实例化。
            ItemsPanel = new FuncTemplate<Panel?>(() => new VirtualizingStackPanel()),
            ItemTemplate = new FuncDataTemplate<List<CardItem>>((row, _) => Row(row), true),
        };
        Content = _list;
        HorizontalAlignment = HorizontalAlignment.Stretch;

        /* ★ 用 SizeChanged 重算列数。
           ★★ 只在**列数真的变了**时才重建 —— 拖窗口时 SizeChanged 每帧都发,
             每次都重建 ItemsSource 的话,拖动过程中会一直在丢弃/重建容器,
             那比不虚拟化还卡。 */
        SizeChanged += (_, _) => Relayout();
    }

    /// <summary>一张卡<b>最少</b>多宽。真实宽度按行宽均分,见 <see cref="Relayout"/>。</summary>
    private double MinCardWidth => _width ?? (_wide ? 256.0 : 158.0);

    /// <summary>这一版算出来的卡片实宽。行里的 Card 就按它建。</summary>
    private double _cardWidth;

    /// <summary>
    /// 重排的防抖。
    /// <para>★★ 拖窗口时 SizeChanged <b>每帧都发</b>,而现在卡片宽度也跟着变 ——
    /// 每帧重建一次 ItemsSource 等于每帧丢弃并重建一屏控件,比不虚拟化还卡。
    /// 列数变了要立刻响应(那是结构变化),纯宽度微调压到停手之后再做。</para>
    /// </summary>
    private DispatcherTimer? _debounce;

    /// <summary>追加一批。分页拉取的网格用 —— 已经画出来的行不重建。</summary>
    public void Append(IEnumerable<CardItem> more)
    {
        _items.AddRange(more);
        Rebuild();
    }

    /// <summary>清空(换排序 / 换筛选)。</summary>
    public void Clear()
    {
        _items.Clear();
        Rebuild();
    }

    public int Count => _items.Count;

    private void Relayout()
    {
        var avail = Bounds.Width;
        if (avail <= 1) return;
        var cols = Math.Max(1, (int)((avail + Gap) / (MinCardWidth + Gap)));
        // ★ 均分:整行宽度减掉列间距,再除以列数。这一步之后右边不剩任何余数。
        var w = Math.Floor((avail - Gap * (cols - 1)) / cols);
        if (cols == _cols && Math.Abs(w - _cardWidth) < 1) return;

        if (cols != _cols)
        {
            // 列数变了 = 结构变了,立刻重排(慢一拍会看到卡片错位)
            _cols = cols; _cardWidth = w;
            _debounce?.Stop();
            Rebuild();
            return;
        }
        // 只是宽度微调:等手停下来再做
        _cardWidth = w;
        _debounce ??= new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(90) };
        _debounce.Stop();
        _debounce.Tick -= OnDebounce;
        _debounce.Tick += OnDebounce;
        _debounce.Start();
    }

    private void OnDebounce(object? sender, EventArgs e)
    {
        _debounce?.Stop();
        Rebuild();
    }

    private void Rebuild()
    {
        if (_cols <= 0)
        {
            // 还没量到宽度(首次挂载)。先按一行铺出去,Relayout 会立刻纠正。
            var w = Bounds.Width;
            _cols = w > 1 ? Math.Max(1, (int)((w + Gap) / (MinCardWidth + Gap))) : 1;
        }
        if (_cardWidth <= 0) _cardWidth = MinCardWidth;
        var rows = new List<List<CardItem>>();
        for (var i = 0; i < _items.Count; i += _cols)
            rows.Add(_items.GetRange(i, Math.Min(_cols, _items.Count - i)));
        _list.ItemsSource = rows;
    }

    private Control Row(List<CardItem> row)
    {
        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Gap,
            Margin = new Thickness(0, 0, 0, Gap + 2),
        };
        foreach (var it in row)
            panel.Children.Add(new Card(_core, _server, it, _wide,
                _onOpen ?? LibraryPage.OpenDetail(_core, _server),
                width: _cardWidth,
                subtitle: _episodeStyle ? it.RuntimeLabel : null,
                title: _episodeStyle ? it.Name : null,
                // 分集标题都是「第 N 集」,一行足够;留两行的话时长会掉到空出来的那行下面。
                titleLines: _episodeStyle ? 1 : _titleLines));
        return panel;
    }
}
