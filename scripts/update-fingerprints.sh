#!/bin/bash
#
# Brittle script to replace all fingerprints. Will run until all fingerprints
# are correct. Intended to be run from the repo's root directory.
#
# This script should only be used to update fingerprints when upstream Triton
# VM is upgraded, not to update fingerprints if the TASM code of the snippet
# changes through manual edits.

FILTER=""
PASS=1

while true; do
    if [ -z "$FILTER" ]; then
        echo "Pass $PASS: Running full test suite to gather initial failures..."
        # First run: We test everything to catch all currently outdated fingerprints
        if OUTPUT=$(cargo nextest run --no-fail-fast --color never 2>&1); then
            echo "Success: All tests passed on pass $PASS!"
            break
        fi
    else
        echo "Pass $PASS: Fast-tracking ONLY the tests that failed in the last pass..."
        # Subsequent runs: We use the -E flag to exclusively target the broken tests
        if OUTPUT=$(cargo nextest run --no-fail-fast --color never -E "$FILTER" 2>&1); then
            echo "Success: All targeted tests have passed!"
            break
        fi
    fi

    # Parse the output and generate a deduplicated sed script
    echo "$OUTPUT" | awk '
        /has signed off on fingerprint/ {
            old = $NF
            gsub(/[^0-9a-fA-Fx]/, "", old)
        }
        /Current fingerprint of/ {
            new = $NF
            gsub(/[^0-9a-fA-Fx]/, "", new)
            if (old != "") {
                print "s/" old "/" new "/g"
                old = ""
            }
        }
    ' | sort -u > update_fingerprints.sed

    # Safety Net: Prevent infinite loops if an actual code bug is causing a failure
    if [ ! -s update_fingerprints.sed ]; then
        echo "Halt: Tests failed, but no fingerprint mismatches were found. Real bug detected."
        break
    fi

    # Apply updates across the codebase
    REPLACEMENTS=$(wc -l < update_fingerprints.sed)
    echo " -> Applied $REPLACEMENTS unique fingerprint updates."
    find tasm-lib/src -type f -name "*.rs" -exec sed -i -f update_fingerprints.sed {} +

    # Build the filter for the next iteration
    # 1. Find lines starting with "FAIL ["
    # 2. Extract the exact test name ($NF)
    # 3. Wrap it in an exact-match Nextest filter: test(=name)
    # 4. Join them all together with the logical OR operator (|)
    FILTER=$(echo "$OUTPUT" | awk '/^[[:space:]]*FAIL \[/ {print "test(=" $NF ")"}' | sort -u | paste -sd "|" -)

    PASS=$((PASS + 1))
done

# Clean up
rm -f update_fingerprints.sed

echo ""
echo "Running one final verification across the entire workspace to ensure complete safety..."
cargo nextest run