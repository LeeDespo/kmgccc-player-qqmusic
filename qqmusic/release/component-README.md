# QQ Music Component Package

这是播放器 Release 为方便替换而提供的**派生组件包**，不是独立组件版本真源。

包内应包含 `qqmusic-helper-next`、`aria2-next`、`components.lock.json`、HelperNext manifest/许可证/
NOTICE/第三方许可证，以及 Aria2 Next GPL-2.0 COPYING。精确来源与 SHA 以 lock 为准。

退出播放器后，把两个可执行文件放到：

```text
~/Library/Application Support/kmgccc.player/QQMusicHelperNext/
```

然后：

```sh
xattr -cr ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext
codesign --force --sign - ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext/qqmusic-helper-next
codesign --force --sign - ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext/aria2-next
```

`Credential/` 是用户凭据目录，替换组件时不要删除或覆盖。
