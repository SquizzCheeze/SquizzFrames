#!/bin/sh
# Guard against the ONE XML mistake this project keeps making.
#
# A prose double-dash inside an <!-- --> comment is illegal XML and kills the
# WHOLE file. WoW does not report it as an XML problem in any useful way -- the
# visible symptom is usually a Lua error about a missing inherited node, or
# simply nothing in that file loading at all, which sends you auditing load
# order for an hour.
#
# Hit three times: UnitFrameButton.xml, then LoadModules.xml twice.
#
# RUN THIS AFTER EVERY XML EDIT:  sh .tools/check-xml.sh
#
# It is comment-aware, so it does not false-positive on the "--" that legally
# ENDS a comment.

cd "$(dirname "$0")/.." || exit 1

found=0
for f in $(find . -name '*.xml' -not -path './Libs/*'); do
    out=$(awk -v F="$f" '
        { line = $0
          while (length(line) > 0) {
              if (inc == 0) {
                  i = index(line, "<!--")
                  if (i == 0) break
                  inc = 1
                  line = substr(line, i + 4)
              } else {
                  e = index(line, "-->")
                  seg = (e ? substr(line, 1, e - 1) : line)
                  if (index(seg, "--") > 0)
                      print F ":" NR ": illegal \"--\" inside an XML comment"
                  if (e) { inc = 0; line = substr(line, e + 3) } else break
              }
          }
        }' "$f")
    if [ -n "$out" ]; then
        echo "$out"
        found=1
    fi
done

if [ "$found" = "1" ]; then
    echo
    echo "Rewrite the prose so the dashes are gone (a full stop usually does it)."
    exit 1
fi

echo "XML comments clean."
