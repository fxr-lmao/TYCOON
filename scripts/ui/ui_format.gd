class_name UiFormat
extends RefCounted

## Number formatting shared by the HUD and the shop. Static only.

## Suffix per power of 1000. Kept as an untyped Array so it stays a valid
## constant expression.
const SUFFIXES: Array = ["", "K", "M", "B", "T", "Qa", "Qi", "Sx"]

## Below this, show the exact number with thousands separators. Above it,
## abbreviate - by then the precise digits are noise.
const EXACT_BELOW: int = 100000


static func money(amount: int) -> String:
	return "$" + number(amount)


## Signed money, for deltas. "+$25" / "-$25".
static func money_delta(amount: int) -> String:
	if amount >= 0:
		return "+" + money(amount)
	return "-" + money(-amount)


static func number(amount: int) -> String:
	var negative: bool = amount < 0
	var value: int = absi(amount)
	var text: String = ""

	if value < EXACT_BELOW:
		text = with_separators(value)
	else:
		var scaled: float = float(value)
		var tier: int = 0
		while scaled >= 1000.0 and tier < SUFFIXES.size() - 1:
			scaled /= 1000.0
			tier += 1
		var suffix: String = SUFFIXES[tier]
		if scaled < 10.0:
			text = "%.2f" % scaled
		elif scaled < 100.0:
			text = "%.1f" % scaled
		else:
			text = "%.0f" % scaled
		text += suffix

	if negative:
		return "-" + text
	return text


static func with_separators(value: int) -> String:
	var digits: String = str(absi(value))
	var out: String = ""
	var since_separator: int = 0
	for i: int in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		since_separator += 1
		if since_separator % 3 == 0 and i > 0:
			out = "," + out
	if value < 0:
		return "-" + out
	return out
