# QQ 音乐数据组件（HelperNext + Aria2 Next）

这两个文件是在线音源的全部取数与下载实现，**可以单独替换**：上游接口变化时换掉它们即可，
不必重新构建应用。应用内的「QQ 音乐设置 → Helper 组件 → 更新组件」也指向这里。

- `qqmusic-helper-next` —— 数据组件：在线内容的读取、登录、限流与熔断。
- `aria2-next` —— 下载引擎（[AnInsomniacy/aria2-next](https://github.com/AnInsomniacy/aria2-next) 2.7.5）：
  歌曲的字节由它搬运。可缺席，缺席时应用会退回自身的下载方式。

## 怎么装

把两个文件放进（覆盖原有文件）：

```
~/Library/Application Support/kmgccc.player/QQMusicHelperNext/
```

然后**两步都不能省**：

```sh
xattr -cr ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext
codesign --force --sign - ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext/*
```

第一步清掉隔离属性，第二步补 ad-hoc 签名。从浏览器下载来的可执行文件带隔离属性，系统会**直接杀掉**它
（退出码 137，没有任何输出），而应用只会写一行日志——表现是"在线音源整个不工作"，看起来像接口失效。
实测只做第一步仍然会被杀，所以第二步也要做。

放好之后回应用点「重新检查」，「组件版本」应当随之更新。

## 协议

stdin 一行一个请求、stdout 一行一个响应，每个响应都回带请求的 `id`：

```json
请求   {"id":"1","method":"fetch_liked_songs","params":{"page":1,"limit":50}}
响应   {"id":"1","ok":true,"likedSongs":{ ... }}
失败   {"id":"1","ok":false,"error":"需要登录后才能读取"}
```

源码在 [QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext)；
应用侧按固定的键名解码，各方法与响应形状的兼容约定见该仓库与本项目 `Tools/helper-next/README.md`。
