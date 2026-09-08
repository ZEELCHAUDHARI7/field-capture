// sv_json.h — a small, self-contained JSON value, parser and writer.
//
// Hand-written rather than vendored. The ABI (architecture §6.4) is JSON, so
// the pipeline needs a parser, but the only JSON it ever sees is our own
// bundle/request/report schema — a few KB of objects, arrays, strings and
// numbers. Pulling in a 25k-line header for that would add a dependency to a
// build R1 spent real effort keeping minimal, and it would have to be
// vendored into the repo to keep the Android and iOS builds offline-clean.
//
// The one subtlety worth knowing about is integer preservation: Dart's
// `jsonInt` rejects `1.0` where it wants `1`, so a number that arrived as an
// integer has to leave as one. See Number/Int below.

#ifndef SV_JSON_H
#define SV_JSON_H

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace sv {

class Json {
 public:
  enum class Type { Null, Bool, Number, String, Array, Object };

  Json() : type_(Type::Null) {}
  static Json null() { return Json(); }
  static Json boolean(bool v);
  static Json number(double v);
  static Json integer(int64_t v);
  static Json string(std::string v);
  static Json array();
  static Json object();

  Type type() const { return type_; }
  bool isNull() const { return type_ == Type::Null; }
  bool isNumber() const { return type_ == Type::Number; }
  bool isString() const { return type_ == Type::String; }
  bool isArray() const { return type_ == Type::Array; }
  bool isObject() const { return type_ == Type::Object; }
  bool isBool() const { return type_ == Type::Bool; }

  // Accessors. These do not throw: a caller asking for the wrong type gets the
  // supplied fallback. Every field in our schema is validated at the read site
  // with a named error instead, which produces a far better message than a
  // type exception from three frames down.
  bool asBool(bool fallback = false) const;
  double asDouble(double fallback = 0.0) const;
  int64_t asInt(int64_t fallback = 0) const;
  const std::string& asString() const;

  // Object access. `has` distinguishes "absent" from "present and null",
  // which matters: a null distortion model is the expected iOS case (Phase 03
  // §2), not a missing field.
  bool has(const std::string& key) const;
  const Json& operator[](const std::string& key) const;
  void set(const std::string& key, Json v);

  // Array access.
  size_t size() const;
  const Json& at(size_t i) const;
  void push(Json v);

  const std::map<std::string, Json>& objectItems() const { return object_; }
  const std::vector<Json>& arrayItems() const { return array_; }

  /// Serialises. [indent] >= 0 pretty-prints, which is what bundle.json and the
  /// report use so a human can diff two runs.
  std::string dump(int indent = -1) const;

  /// Parses [text]. Returns false and fills [error] on malformed input, rather
  /// than throwing — the C ABI has to turn this into a return code anyway.
  static bool parse(const std::string& text, Json& out, std::string& error);

 private:
  Type type_;
  bool bool_ = false;
  double number_ = 0.0;
  bool isInt_ = false;   ///< preserve integer-ness across a round trip
  int64_t int_ = 0;
  std::string string_;
  std::vector<Json> array_;
  std::map<std::string, Json> object_;

  void dumpTo(std::string& out, int indent, int depth) const;
};

}  // namespace sv

#endif  // SV_JSON_H
