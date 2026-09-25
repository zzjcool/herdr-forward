// jsonjq.go — jq 兼容的 JSON 值模型与编码器（W4 内部实现，不对外冻结）。
//
// 为什么不能直接用 encoding/json：
//
//  1. `list --json` 的历史行为是 `forward_list_json | jq -S -c '{version:$v,forwards:.}'`，
//     即**原样透传**状态文件里的记录 —— 未知键要保留、缺失键要缺失、数字字面量要逐字节
//     保留（`2.50` 不能变成 `2.5`）。类型化模型（state.Forward）做不到这一点。
//  2. jq 的字符串转义与 Go 的 encoding/json **不同**（od 逐字节实测）：jq 只转义
//     `"` `\` `\b` `\t` `\n` `\f` `\r`、< 0x20 与 0x7f；U+2028/U+2029 原样输出；
//     `<` `>` `&` 不转义；它也不做 UTF-8 替换字符处理。
//  3. jq 的数字输出经 decNumber 规范化（`1e3` -> `1E+3`、`2.50` -> `2.50`、
//     `0.0000001` -> `1E-7`），与 Go 的 strconv 输出不同。
//
// 因此这里自带一个「顺序保留对象 + 保留数字字面量」的模型：用 json.Decoder 的
// Token() 流式解析（UseNumber 保留字面量），用下面的编码器按 jq 的规则输出。
// golden 全部来自本机 jq 1.8.2 的实测输出（见 cli_test.go 的表驱动用例）。
package jqjson

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
)

// Number 是保留字面量的数字类型别名（json.Decoder.UseNumber 产出 json.Number）。
// 用别名而非新类型，避免在解析结果里混入需要转换的类型。
type Number = json.Number

// NumberLiteral 把十进制字面量包成 json.Number（只在构造视图行时用）。
func NumberLiteral(lit string) json.Number { return json.Number(lit) }

// Object 是「保留键插入顺序」的 JSON 对象。
//
// 必要性：jq 的 `to_entries` / 对象迭代都按插入顺序（`-S` 只在**输出时**按键排序），
// 而 `status` 对象的 to_entries 顺序决定 `bridge_live_status_json` 里
// 「同 id 多条报告」的 tie-break 结果。Go 的 map 无法提供这一保证。
type Object struct {
	keys []string
	vals map[string]any
}

func NewObject() *Object { return &Object{vals: map[string]any{}} }

// set 写入键值；已存在的键保持原位置（jq 的对象更新语义：就地改值，不挪位置）。
// Set 写入键值；已存在的键保持原位置（jq 的对象更新语义：就地改值，不挪位置）。
func (o *Object) Set(key string, val any) { o.set(key, val) }

func (o *Object) set(key string, val any) {
	if _, ok := o.vals[key]; !ok {
		o.keys = append(o.keys, key)
	}
	o.vals[key] = val
}

// Get 取值；缺失键返回 (nil, false)。
func (o *Object) Get(key string) (any, bool) { return o.get(key) }

// Keys 返回键的插入顺序（复刻 jq 的对象迭代序）。
func (o *Object) Keys() []string { return o.keys }

// Val 取键值（缺失返回 nil）。
func (o *Object) Val(key string) any {
	v, _ := o.vals[key]
	return v
}

// get 取值；缺失键返回 (nil, false)。
func (o *Object) get(key string) (any, bool) {
	v, ok := o.vals[key]
	return v, ok
}

// MarshalJSON 让 Object 也能直接喂给 encoding/json（键按插入序，不排序）。
func (o *Object) MarshalJSON() ([]byte, error) {
	return []byte(Encode(o, false)), nil
}

// Parse 解析**一个**完整 JSON 值（允许首尾空白，不允许多余内容）。
// 与 jq 对齐：任何语法错误都返回 error（调用方据此走 warn 降级路径）。
func Parse(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	v, err := decodeValue(dec)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("json: 尾随内容不是合法 JSON")
	}
	return v, nil
}

func decodeValue(dec *json.Decoder) (any, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	return decodeFromToken(dec, tok)
}

func decodeFromToken(dec *json.Decoder, tok json.Token) (any, error) {
	delim, isDelim := tok.(json.Delim)
	if !isDelim {
		// string / json.Number / bool / nil 都是可直接使用的叶子值
		return tok, nil
	}
	switch delim {
	case '{':
		obj := NewObject()
		for dec.More() {
			kt, err := dec.Token()
			if err != nil {
				return nil, err
			}
			key, ok := kt.(string)
			if !ok {
				return nil, fmt.Errorf("json: 对象键不是字符串")
			}
			val, err := decodeValue(dec)
			if err != nil {
				return nil, err
			}
			obj.set(key, val)
		}
		if _, err := dec.Token(); err != nil { // 消费 '}'
			return nil, err
		}
		return obj, nil
	case '[':
		arr := []any{}
		for dec.More() {
			val, err := decodeValue(dec)
			if err != nil {
				return nil, err
			}
			arr = append(arr, val)
		}
		if _, err := dec.Token(); err != nil { // 消费 ']'
			return nil, err
		}
		return arr, nil
	default:
		return nil, fmt.Errorf("json: 意外的分隔符 %v", delim)
	}
}

// Encode 按 jq 的规则把值模型编码成紧凑 JSON。
//
//	sorted=false —— 保留对象键插入顺序（对位 `jq -c`，如 `ports --json`）
//	sorted=true  —— 对象键递归按字母序排列（对位 `jq -S -c`，如 `list --json`）
func Encode(v any, sorted bool) string {
	var b strings.Builder
	writeValue(&b, v, sorted)
	return b.String()
}

func writeValue(b *strings.Builder, v any, sorted bool) {
	switch t := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		if t {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case string:
		b.WriteString(EncodeString(t))
	case json.Number:
		b.WriteString(FormatNumber(t.String()))
	case *Object:
		keys := t.keys
		if sorted {
			keys = append([]string(nil), t.keys...)
			sort.Strings(keys)
		}
		b.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(EncodeString(k))
			b.WriteByte(':')
			writeValue(b, t.vals[k], sorted)
		}
		b.WriteByte('}')
	case []any:
		b.WriteByte('[')
		for i, e := range t {
			if i > 0 {
				b.WriteByte(',')
			}
			writeValue(b, e, sorted)
		}
		b.WriteByte(']')
	default:
		// 兜底：本包不会构造其它类型；真出现时退化为 Go 默认打印（不可达路径）
		fmt.Fprintf(b, "%v", t)
	}
}

// EncodeString 复刻 jq 的字符串转义（od 逐字节实测）：
//
//	"  -> \"     \  -> \\     \b -> \b     \t -> \t
//	\n -> \n     \f -> \f     \r -> \r
//	其余 < 0x20 与 0x7f -> \u00xx（小写十六进制）
//	别的字节原样输出（UTF-8 原样；U+2028/U+2029 不转义，`<` `>` `&` 不转义）
func EncodeString(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\t':
			b.WriteString(`\t`)
		case '\n':
			b.WriteString(`\n`)
		case '\f':
			b.WriteString(`\f`)
		case '\r':
			b.WriteString(`\r`)
		default:
			if c < 0x20 || c == 0x7f {
				fmt.Fprintf(&b, `\u%04x`, c)
				continue
			}
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// FormatNumber 把 JSON 数字字面量重排成 jq（decNumber）的输出形态。
//
// 算法即 decNumber 的 decNumberToString（用实测的 ~60 个字面量反推并验证）：
//
//	digits = 整数部分 + 小数部分，去掉前导零（全零 -> "0"）
//	exp    = 显式指数 - 小数部分位数
//	adj    = exp + len(digits) - 1
//	若 exp > 0 或 adj < -6 -> 科学计数 d1[.d2…]E±|adj|（E 恒带符号、无前导零）
//	否则定点：小数点落在 len(digits)+exp 处（<=0 时补 "0." + 零）
//
// 例：1e3->1E+3，1.5e3->1.5E+3，1e-6->0.000001，1e-7->1E-7，0.0000000->0E-7，
// 2.50->2.50，-0->-0，0e5->0E+5，1000000e-6->1.000000，1.000000e-7->1.000000E-7。
func FormatNumber(lit string) string {
	s := lit
	sign := ""
	if strings.HasPrefix(s, "-") {
		sign = "-"
		s = s[1:]
	} else {
		s = strings.TrimPrefix(s, "+")
	}

	mant, expText := s, ""
	if i := strings.IndexAny(s, "eE"); i >= 0 {
		mant, expText = s[:i], s[i+1:]
	}
	intPart, fracPart := mant, ""
	if i := strings.Index(mant, "."); i >= 0 {
		intPart, fracPart = mant[:i], mant[i+1:]
	}

	digits := strings.TrimLeft(intPart+fracPart, "0")
	if digits == "" {
		digits = "0"
	}

	exp := 0
	if expText != "" {
		if n, err := strconv.Atoi(expText); err == nil {
			exp = n
		}
	}
	exp -= len(fracPart)
	adjusted := exp + len(digits) - 1

	var out string
	if exp > 0 || adjusted < -6 {
		out = digits[:1]
		if len(digits) > 1 {
			out += "." + digits[1:]
		}
		if adjusted >= 0 {
			out += "E+" + strconv.Itoa(adjusted)
		} else {
			out += "E-" + strconv.Itoa(-adjusted)
		}
		return sign + out
	}

	point := len(digits) + exp
	switch {
	case point <= 0:
		out = "0." + strings.Repeat("0", -point) + digits
	case point >= len(digits):
		out = digits + strings.Repeat("0", point-len(digits))
	default:
		out = digits[:point] + "." + digits[point:]
	}
	return sign + out
}

// Truthy 复刻 jq 的真值判定：只有 null 与 false 是「假」，其余（含 0、""）为真。
func Truthy(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case bool:
		return t
	default:
		return true
	}
}

// TypeName 复刻 jq 的 `type` 输出（object/array/string/number/boolean/null）。
func TypeName(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case string:
		return "string"
	case json.Number:
		return "number"
	case []any:
		return "array"
	case *Object:
		return "object"
	default:
		return "unknown"
	}
}

// ToString 复刻 jq 的 `tostring`：数字保留字面量形态、字符串原样、
// 对象/数组用紧凑（键序保留）形态、null -> "null"。
func ToString(v any) string {
	switch t := v.(type) {
	case nil:
		return "null"
	case string:
		return t
	case bool:
		if t {
			return "true"
		}
		return "false"
	case json.Number:
		return FormatNumber(t.String())
	default:
		return Encode(v, false)
	}
}

// Str 取字符串（jq 里 `(.x // "")` 的 Go 化）：非字符串一律当空串。
func Str(v any) string {
	s, _ := v.(string)
	return s
}
