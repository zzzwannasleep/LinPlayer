package ranking

import "os"

// 两个上游的基址 + TMDB 的图床基址。
//
// ★ 做成**变量**而不是常量,是为了让测试能指向一台假服务器。
// 排行榜这块的判据全是「服务端拒绝时说不说得清原因」—— 只有真起一台会拒绝的
// 服务器才验得到,拿常量就只能跑真上游(要网络、要凭据、还会抽风)。
var (
	dandanBase = "https://api.dandanplay.net"
	tmdbBase   = "https://api.themoviedb.org/3"
	// tmdbImgBase TMDB 只给 poster_path(如 /abc.jpg),要自己拼图床前缀。
	tmdbImgBase = "https://image.tmdb.org/t/p/w342"
)

// selfCheckOrigins 自检时额外要放行的图床 origin(见下面 init 的说明)。
var selfCheckOrigins []string

// 环境变量覆盖:给**真机自检**用(scripts/selfcheck-win.sh)。
//
// ★★ 为什么非要有这个:排行榜**有凭据时长什么样**,是单测验不到的 ——
// 凭据是编译期注入的,而页面渲染只有真 exe 跑起来才现形。本仓库栽过两次
// 「预置形状 ≠ 真实形状」(自检永远灌配置没走过真登录 / 假服务器不开 gzip),
// 所以这条路必须能在真 exe 上端到端走一遍。
//
// ★ 只认环境变量,不进配置、不进命令 —— 用户点不到,也没有 UI 能设它。
// ★ 覆盖了基址就得**同时**放行对应的图床 origin,否则自检里「数据有、图全空」,
//   而那恰好是白名单漏了时的真实症状 —— 两者混在一起就白验了。
func init() {
	if v := os.Getenv("LP_RANKING_BASE_DANDAN"); v != "" {
		dandanBase = v
		selfCheckOrigins = append(selfCheckOrigins, v)
	}
	if v := os.Getenv("LP_RANKING_BASE_TMDB"); v != "" {
		tmdbBase = v
		selfCheckOrigins = append(selfCheckOrigins, v)
	}
	if v := os.Getenv("LP_RANKING_BASE_TMDBIMG"); v != "" {
		tmdbImgBase = v
		selfCheckOrigins = append(selfCheckOrigins, v)
	}
}

// setBasesForTest 只给本包测试用,返回还原函数。
func setBasesForTest(dandan, tmdb string) func() {
	od, ot := dandanBase, tmdbBase
	dandanBase, tmdbBase = dandan, tmdb
	return func() { dandanBase, tmdbBase = od, ot }
}
