/// The signed-in Asite user.
///
/// Named FieldUser rather than User to avoid colliding with the many `User`
/// types a real Asite SDK will bring later.
class FieldUser {
  const FieldUser({
    required this.id,
    required this.email,
    required this.displayName,
  });

  final String id;
  final String email;
  final String displayName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is FieldUser && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
