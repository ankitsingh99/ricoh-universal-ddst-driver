## Description

<!-- Describe the changes proposed in this Pull Request and why they were made. -->

## Type of Change

- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature or hardware support (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Build / CI improvement

## Testing Checklist

Please verify the following where applicable:

- [ ] Driver compiles cleanly without warnings (`make clean && make build`)
- [ ] PPD profiles validate with `for f in ppd/*.ppd; do cupstestppd "$f"; done`
- [ ] Shell scripts pass syntax check (`bash -n setup.sh test_print.sh uninstall.sh`)
- [ ] Tested on macOS (if applicable)
- [ ] Tested on Linux (if applicable)
- [ ] Physical printer test page verified (if hardware available)

## Related Issues

<!-- Closes #123 or Fixes #456 -->
