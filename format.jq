# Name-Felder zuerst, Listen unter apps/fields/relationships/values je Element einzeilig.

def sp($n): [range(0; $n) | " "] | join("");

def walkname: walk(if type == "object" and has("name") then {name} + . else . end);

def ser($n; $key):
  if type == "array" then
    if length == 0 then "[]"
    elif ($key == "apps" or $key == "fields" or $key == "relationships" or $key == "values") then
      "[\n" + (map(sp($n + 2) + (walkname | tojson)) | join(",\n")) + "\n" + sp($n) + "]"
    else
      "[\n" + (map(sp($n + 2) + ser($n + 2; null)) | join(",\n")) + "\n" + sp($n) + "]"
    end
  elif type == "object" then
    if length == 0 then "{}"
    else
      "{\n" + (to_entries
        | sort_by(.key != "name")
        | map(. as $e | sp($n + 2) + ($e.key | tojson) + ": " + ($e.value | ser($n + 2; $e.key)))
        | join(",\n")) + "\n" + sp($n) + "}"
    end
  else tojson
  end;

ser(0; null)
