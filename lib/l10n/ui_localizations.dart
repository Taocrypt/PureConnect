import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/l10n.dart';

/// Strings prism_ui's own components show.
class AppUiLocalizations implements UiLocalizations {
  const AppUiLocalizations(this.zh);

  final bool zh;

  static const LocalizationsDelegate<UiLocalizations> delegate = _Delegate();

  String _t(String en, String cn) => zh ? cn : en;

  @override
  String get back => _t('Back', '返回');
  @override
  String get cancel => _t('Cancel', '取消');
  @override
  String get clearSearch => _t('Clear search', '清除搜索');
  @override
  String get close => _t('Close', '关闭');
  @override
  String get copy => _t('Copy', '复制');
  @override
  String get cut => _t('Cut', '剪切');
  @override
  String get dialog => _t('Dialog', '对话框');
  @override
  String get hidePassword => _t('Hide password', '隐藏密码');
  @override
  String get more => _t('More', '更多');
  @override
  String get noSearchResults => _t('No results', '无结果');
  @override
  String get paste => _t('Paste', '粘贴');
  @override
  String get reset => _t('Reset', '重置');
  @override
  String get select => _t('Select', '选择');
  @override
  String get search => _t('Search', '搜索');
  @override
  String get selectAll => _t('Select all', '全选');
  @override
  String get showLess => _t('Show less', '收起');
  @override
  String get showMore => _t('Show more', '展开');
  @override
  String get showPassword => _t('Show password', '显示密码');
  @override
  String get sort => _t('Sort', '排序');
  @override
  String get submit => _t('Submit', '提交');
}

class _Delegate extends LocalizationsDelegate<UiLocalizations> {
  const _Delegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<UiLocalizations> load(Locale locale) =>
      SynchronousFuture(AppUiLocalizations(locale.languageCode == 'zh'));

  @override
  bool shouldReload(_Delegate old) => false;
}
