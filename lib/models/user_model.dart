class User {
  final int? id;
  final String username;
  final String passwordHash;
  final String fullName;
  final String role;
  final int? cashBoxAccountId;

  User({
    this.id,
    required this.username,
    required this.passwordHash,
    required this.fullName,
    required this.role,
    this.cashBoxAccountId,
  });

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['id'],
      username: map['username'],
      passwordHash: map['password_hash'],
      fullName: map['full_name'],
      role: map['role'],
      cashBoxAccountId: map['cash_box_account_id'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'password_hash': passwordHash,
      'full_name': fullName,
      'role': role,
      'cash_box_account_id': cashBoxAccountId,
    };
  }
}
