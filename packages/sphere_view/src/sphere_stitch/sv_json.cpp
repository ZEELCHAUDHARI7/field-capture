#include "sv_json.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace sv {
namespace {

const Json& nullJson() {
  static const Json instance;
  return instance;
}

const std::string& emptyString() {
  static const std::string instance;
  return instance;
}

/// Shortest representation that still round-trips exactly.
///
/// `%.17g` always round-trips but prints 0.1 as 0.10000000000000001, which
/// makes a report unreadable and a diff between two runs useless. Try the
/// shorter forms first and keep the first one that reads back bit-identical.
std::string formatDouble(double v) {
  if (std::isnan(v) || std::isinf(v)) return "null";  // JSON has no NaN/Inf
  char buf[40];
  for (int precision = 15; precision <= 17; ++precision) {
    std::snprintf(buf, sizeof(buf), "%.*g", precision, v);
    if (std::strtod(buf, nullptr) == v) break;
  }
  return std::string(buf);
}

void encodeUtf8(uint32_t cp, std::string& out) {
  if (cp < 0x80) {
    out += static_cast<char>(cp);
  } else if (cp < 0x800) {
    out += static_cast<char>(0xC0 | (cp >> 6));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  } else if (cp < 0x10000) {
    out += static_cast<char>(0xE0 | (cp >> 12));
    out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  } else {
    out += static_cast<char>(0xF0 | (cp >> 18));
    out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
    out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  }
}

void escapeTo(const std::string& s, std::string& out) {
  out += '"';
  for (unsigned char c : s) {
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b";  break;
      case '\f': out += "\\f";  break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  out += '"';
}

class Parser {
 public:
  Parser(const std::string& text, std::string& error)
      : s_(text), error_(error) {}

  bool parseValue(Json& out) {
    skipWhitespace();
    if (pos_ >= s_.size()) return fail("unexpected end of input");
    switch (s_[pos_]) {
      case '{': return parseObject(out);
      case '[': return parseArray(out);
      case '"': {
        std::string v;
        if (!parseString(v)) return false;
        out = Json::string(std::move(v));
        return true;
      }
      case 't':
        if (!literal("true")) return false;
        out = Json::boolean(true);
        return true;
      case 'f':
        if (!literal("false")) return false;
        out = Json::boolean(false);
        return true;
      case 'n':
        if (!literal("null")) return false;
        out = Json::null();
        return true;
      default: return parseNumber(out);
    }
  }

  bool atEndAfterWhitespace() {
    skipWhitespace();
    return pos_ >= s_.size();
  }

  size_t pos() const { return pos_; }

 private:
  const std::string& s_;
  std::string& error_;
  size_t pos_ = 0;

  bool fail(const std::string& why) {
    error_ = why + " at offset " + std::to_string(pos_);
    return false;
  }

  void skipWhitespace() {
    while (pos_ < s_.size()) {
      char c = s_[pos_];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') ++pos_;
      else break;
    }
  }

  bool literal(const char* text) {
    size_t n = std::strlen(text);
    if (s_.compare(pos_, n, text) != 0) return fail(std::string("expected ") + text);
    pos_ += n;
    return true;
  }

  bool parseNumber(Json& out) {
    size_t start = pos_;
    if (pos_ < s_.size() && (s_[pos_] == '-' || s_[pos_] == '+')) ++pos_;
    bool isInteger = true;
    while (pos_ < s_.size()) {
      char c = s_[pos_];
      if (c >= '0' && c <= '9') { ++pos_; continue; }
      if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
        isInteger = false;
        ++pos_;
        continue;
      }
      break;
    }
    if (pos_ == start) return fail("expected a number");
    std::string text = s_.substr(start, pos_ - start);
    if (isInteger) {
      errno = 0;
      char* end = nullptr;
      long long v = std::strtoll(text.c_str(), &end, 10);
      // Fall through to double for values that do not fit an int64 — better a
      // lossy double than a silently wrapped integer.
      if (errno == 0 && end && *end == '\0') {
        out = Json::integer(static_cast<int64_t>(v));
        return true;
      }
    }
    char* end = nullptr;
    double v = std::strtod(text.c_str(), &end);
    if (!end || *end != '\0') return fail("malformed number '" + text + "'");
    out = Json::number(v);
    return true;
  }

  bool parseString(std::string& out) {
    if (s_[pos_] != '"') return fail("expected a string");
    ++pos_;
    out.clear();
    while (true) {
      if (pos_ >= s_.size()) return fail("unterminated string");
      char c = s_[pos_++];
      if (c == '"') return true;
      if (c != '\\') { out += c; continue; }
      if (pos_ >= s_.size()) return fail("unterminated escape");
      char e = s_[pos_++];
      switch (e) {
        case '"':  out += '"';  break;
        case '\\': out += '\\'; break;
        case '/':  out += '/';  break;
        case 'b':  out += '\b'; break;
        case 'f':  out += '\f'; break;
        case 'n':  out += '\n'; break;
        case 'r':  out += '\r'; break;
        case 't':  out += '\t'; break;
        case 'u': {
          uint32_t cp = 0;
          if (!hex4(cp)) return false;
          // A high surrogate must be followed by its low partner; otherwise the
          // code point is not representable and the input is malformed.
          if (cp >= 0xD800 && cp <= 0xDBFF) {
            if (pos_ + 1 < s_.size() && s_[pos_] == '\\' && s_[pos_ + 1] == 'u') {
              pos_ += 2;
              uint32_t low = 0;
              if (!hex4(low)) return false;
              if (low < 0xDC00 || low > 0xDFFF) return fail("bad low surrogate");
              cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
            } else {
              return fail("unpaired high surrogate");
            }
          }
          encodeUtf8(cp, out);
          break;
        }
        default: return fail("unknown escape");
      }
    }
  }

  bool hex4(uint32_t& out) {
    if (pos_ + 4 > s_.size()) return fail("truncated \\u escape");
    out = 0;
    for (int i = 0; i < 4; ++i) {
      char c = s_[pos_++];
      out <<= 4;
      if (c >= '0' && c <= '9') out |= static_cast<uint32_t>(c - '0');
      else if (c >= 'a' && c <= 'f') out |= static_cast<uint32_t>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') out |= static_cast<uint32_t>(c - 'A' + 10);
      else return fail("bad hex digit in \\u escape");
    }
    return true;
  }

  bool parseArray(Json& out) {
    ++pos_;  // '['
    out = Json::array();
    skipWhitespace();
    if (pos_ < s_.size() && s_[pos_] == ']') { ++pos_; return true; }
    while (true) {
      Json item;
      if (!parseValue(item)) return false;
      out.push(std::move(item));
      skipWhitespace();
      if (pos_ >= s_.size()) return fail("unterminated array");
      if (s_[pos_] == ',') { ++pos_; continue; }
      if (s_[pos_] == ']') { ++pos_; return true; }
      return fail("expected ',' or ']'");
    }
  }

  bool parseObject(Json& out) {
    ++pos_;  // '{'
    out = Json::object();
    skipWhitespace();
    if (pos_ < s_.size() && s_[pos_] == '}') { ++pos_; return true; }
    while (true) {
      skipWhitespace();
      std::string key;
      if (pos_ >= s_.size() || s_[pos_] != '"') return fail("expected an object key");
      if (!parseString(key)) return false;
      skipWhitespace();
      if (pos_ >= s_.size() || s_[pos_] != ':') return fail("expected ':'");
      ++pos_;
      Json value;
      if (!parseValue(value)) return false;
      out.set(key, std::move(value));
      skipWhitespace();
      if (pos_ >= s_.size()) return fail("unterminated object");
      if (s_[pos_] == ',') { ++pos_; continue; }
      if (s_[pos_] == '}') { ++pos_; return true; }
      return fail("expected ',' or '}'");
    }
  }
};

}  // namespace

Json Json::boolean(bool v) { Json j; j.type_ = Type::Bool; j.bool_ = v; return j; }
Json Json::number(double v) { Json j; j.type_ = Type::Number; j.number_ = v; j.isInt_ = false; return j; }
Json Json::string(std::string v) { Json j; j.type_ = Type::String; j.string_ = std::move(v); return j; }
Json Json::array() { Json j; j.type_ = Type::Array; return j; }
Json Json::object() { Json j; j.type_ = Type::Object; return j; }

Json Json::integer(int64_t v) {
  Json j;
  j.type_ = Type::Number;
  j.isInt_ = true;
  j.int_ = v;
  j.number_ = static_cast<double>(v);
  return j;
}

bool Json::asBool(bool fallback) const {
  if (type_ == Type::Bool) return bool_;
  return fallback;
}

double Json::asDouble(double fallback) const {
  if (type_ != Type::Number) return fallback;
  return isInt_ ? static_cast<double>(int_) : number_;
}

int64_t Json::asInt(int64_t fallback) const {
  if (type_ != Type::Number) return fallback;
  return isInt_ ? int_ : static_cast<int64_t>(llround(number_));
}

const std::string& Json::asString() const {
  return type_ == Type::String ? string_ : emptyString();
}

bool Json::has(const std::string& key) const {
  return type_ == Type::Object && object_.find(key) != object_.end();
}

const Json& Json::operator[](const std::string& key) const {
  if (type_ != Type::Object) return nullJson();
  auto it = object_.find(key);
  return it == object_.end() ? nullJson() : it->second;
}

void Json::set(const std::string& key, Json v) {
  type_ = Type::Object;
  object_[key] = std::move(v);
}

size_t Json::size() const {
  if (type_ == Type::Array) return array_.size();
  if (type_ == Type::Object) return object_.size();
  return 0;
}

const Json& Json::at(size_t i) const {
  if (type_ != Type::Array || i >= array_.size()) return nullJson();
  return array_[i];
}

void Json::push(Json v) {
  type_ = Type::Array;
  array_.push_back(std::move(v));
}

std::string Json::dump(int indent) const {
  std::string out;
  dumpTo(out, indent, 0);
  return out;
}

void Json::dumpTo(std::string& out, int indent, int depth) const {
  const bool pretty = indent >= 0;
  const std::string pad = pretty ? std::string(static_cast<size_t>(indent * (depth + 1)), ' ') : std::string();
  const std::string padEnd = pretty ? std::string(static_cast<size_t>(indent * depth), ' ') : std::string();

  switch (type_) {
    case Type::Null:   out += "null"; return;
    case Type::Bool:   out += bool_ ? "true" : "false"; return;
    case Type::Number:
      out += isInt_ ? std::to_string(int_) : formatDouble(number_);
      return;
    case Type::String: escapeTo(string_, out); return;
    case Type::Array: {
      if (array_.empty()) { out += "[]"; return; }
      out += '[';
      for (size_t i = 0; i < array_.size(); ++i) {
        if (i) out += ',';
        if (pretty) { out += '\n'; out += pad; }
        array_[i].dumpTo(out, indent, depth + 1);
      }
      if (pretty) { out += '\n'; out += padEnd; }
      out += ']';
      return;
    }
    case Type::Object: {
      if (object_.empty()) { out += "{}"; return; }
      out += '{';
      bool first = true;
      for (const auto& entry : object_) {
        if (!first) out += ',';
        first = false;
        if (pretty) { out += '\n'; out += pad; }
        escapeTo(entry.first, out);
        out += ':';
        if (pretty) out += ' ';
        entry.second.dumpTo(out, indent, depth + 1);
      }
      if (pretty) { out += '\n'; out += padEnd; }
      out += '}';
      return;
    }
  }
}

bool Json::parse(const std::string& text, Json& out, std::string& error) {
  Parser parser(text, error);
  if (!parser.parseValue(out)) return false;
  if (!parser.atEndAfterWhitespace()) {
    error = "trailing content at offset " + std::to_string(parser.pos());
    return false;
  }
  return true;
}

}  // namespace sv
