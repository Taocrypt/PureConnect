import 'dart:math';

enum VpnProtocol { easyconnect, atrust }

/// aTrust primary auth types understood by zju-connect (`auth_type`).
enum AtrustAuthType {
  auto(''),
  password('auth/psw'),
  sms('auth/smsCheckCode'),
  cas('auth/cas'),
  oauth2('auth/httpsOauth2');

  const AtrustAuthType(this.value);
  final String value;

  static AtrustAuthType fromValue(String? v) =>
      values.firstWhere((e) => e.value == v, orElse: () => AtrustAuthType.auto);
}

/// One server account. Everything that identifies *who* logs in *where*;
/// network behaviour lives in [AppSettings].
class Profile {
  Profile({
    String? id,
    required this.name,
    this.protocol = VpnProtocol.easyconnect,
    this.serverAddress = '',
    this.serverPort = 443,
    this.username = '',
    this.password = '',
    this.totpSecret = '',
    // EasyConnect
    this.certFile = '',
    this.certPassword = '',
    this.twfId = '',
    this.disableZjuConfig = false,
    this.skipDomainResource = false,
    this.disableMultiLine = false,
    this.disableServerConfig = false,
    // aTrust
    this.authType = AtrustAuthType.auto,
    this.phone = '',
    this.loginDomain = 'Radius',
    this.casTicket = '',
    this.oauth2Code = '',
    this.saveClientData = true,
    this.macAddresses = const [],
  }) : id = id ?? _newId();

  final String id;
  String name;
  VpnProtocol protocol;
  String serverAddress;
  int serverPort;
  String username;
  String password;
  String totpSecret;

  String certFile;
  String certPassword;
  String twfId;
  bool disableZjuConfig;
  bool skipDomainResource;
  bool disableMultiLine;
  bool disableServerConfig;

  AtrustAuthType authType;
  String phone;
  String loginDomain;
  String casTicket;
  String oauth2Code;
  bool saveClientData;
  List<String> macAddresses;

  /// Server is one of ZJU's (empty address falls back to ZJU's).
  bool get isZjuHost {
    final h = effectiveServer.toLowerCase();
    return h == 'zju.edu.cn' || h.endsWith('.zju.edu.cn');
  }

  bool get isZju =>
      serverAddress.isEmpty ||
      serverAddress == 'rvpn.zju.edu.cn' ||
      serverAddress == 'vpn.zju.edu.cn';

  String get effectiveServer => serverAddress.isNotEmpty
      ? serverAddress
      : (protocol == VpnProtocol.atrust ? 'vpn.zju.edu.cn' : 'rvpn.zju.edu.cn');

  static String _newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      Random().nextInt(1 << 20).toRadixString(36);

  factory Profile.zjuEasyConnect() =>
      Profile(name: 'ZJU RVPN (EasyConnect)', serverAddress: 'rvpn.zju.edu.cn');

  factory Profile.zjuAtrust() => Profile(
        name: 'ZJU VPN (aTrust)',
        protocol: VpnProtocol.atrust,
        serverAddress: 'vpn.zju.edu.cn',
        authType: AtrustAuthType.password,
      );

  Profile copy() => Profile.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol.name,
        'serverAddress': serverAddress,
        'serverPort': serverPort,
        'username': username,
        'password': password,
        'totpSecret': totpSecret,
        'certFile': certFile,
        'certPassword': certPassword,
        'twfId': twfId,
        'disableZjuConfig': disableZjuConfig,
        'skipDomainResource': skipDomainResource,
        'disableMultiLine': disableMultiLine,
        'disableServerConfig': disableServerConfig,
        'authType': authType.value,
        'phone': phone,
        'loginDomain': loginDomain,
        'casTicket': casTicket,
        'oauth2Code': oauth2Code,
        'saveClientData': saveClientData,
        'macAddresses': macAddresses,
      };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String?,
        name: j['name'] as String? ?? 'Profile',
        protocol: VpnProtocol.values.firstWhere((e) => e.name == j['protocol'],
            orElse: () => VpnProtocol.easyconnect),
        serverAddress: j['serverAddress'] as String? ?? '',
        serverPort: j['serverPort'] as int? ?? 443,
        username: j['username'] as String? ?? '',
        password: j['password'] as String? ?? '',
        totpSecret: j['totpSecret'] as String? ?? '',
        certFile: j['certFile'] as String? ?? '',
        certPassword: j['certPassword'] as String? ?? '',
        twfId: j['twfId'] as String? ?? '',
        disableZjuConfig: j['disableZjuConfig'] as bool? ?? false,
        skipDomainResource: j['skipDomainResource'] as bool? ?? false,
        disableMultiLine: j['disableMultiLine'] as bool? ?? false,
        disableServerConfig: j['disableServerConfig'] as bool? ?? false,
        authType: AtrustAuthType.fromValue(j['authType'] as String?),
        phone: j['phone'] as String? ?? '',
        loginDomain: j['loginDomain'] as String? ?? 'Radius',
        casTicket: j['casTicket'] as String? ?? '',
        oauth2Code: j['oauth2Code'] as String? ?? '',
        saveClientData: j['saveClientData'] as bool? ?? true,
        macAddresses:
            (j['macAddresses'] as List?)?.cast<String>() ?? const <String>[],
      );
}
