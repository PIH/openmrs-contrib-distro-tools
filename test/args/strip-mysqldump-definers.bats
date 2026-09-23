#!/usr/bin/env bats
# strip-mysqldump-definers removes DEFINER clauses (and nothing else) into a new file, converting
# between plain and gzip-compressed SQL based on each file's own extension.

load ../helpers

setup() {
    cd "$BATS_TEST_TMPDIR"
    cat > dump.sql <<'EOF'
CREATE TABLE `t` (`id` int);
/*!50003 CREATE*/ /*!50017 DEFINER=`legacy`@`localhost`*/ /*!50003 TRIGGER t_ins BEFORE INSERT ON t FOR EACH ROW SET @x = 1 */;;
CREATE DEFINER=`root`@`%` PROCEDURE `p`() SELECT 1;
/*!50013 DEFINER=`legacy`@`10.0.0.%` SQL SECURITY DEFINER */
INSERT INTO `t` VALUES (1);
EOF
    # Hand-written expectation: every DEFINER=`user`@`host` clause gone, all else byte-for-byte.
    cat > expected.sql <<'EOF'
CREATE TABLE `t` (`id` int);
/*!50003 CREATE*/ /*!50017 */ /*!50003 TRIGGER t_ins BEFORE INSERT ON t FOR EACH ROW SET @x = 1 */;;
CREATE  PROCEDURE `p`() SELECT 1;
/*!50013  SQL SECURITY DEFINER */
INSERT INTO `t` VALUES (1);
EOF
}
teardown() { common_teardown; }

@test "strips DEFINER clauses from a plain dump into a plain dump" {
    run "$UTILS/strip-mysqldump-definers.sh" --path=dump.sql --output=out.sql
    assert_success
    assert_equal "$(cat out.sql)" "$(cat expected.sql)"
}

@test "reads a gzipped dump and writes a plain one" {
    gzip -k dump.sql
    run "$UTILS/strip-mysqldump-definers.sh" --path=dump.sql.gz --output=out.sql
    assert_success
    assert_equal "$(cat out.sql)" "$(cat expected.sql)"
}

@test "writes gzip when the output ends in .gz" {
    run "$UTILS/strip-mysqldump-definers.sh" --path=dump.sql --output=out.sql.gz
    assert_success
    run gzip -t out.sql.gz
    assert_success
    assert_equal "$(zcat out.sql.gz)" "$(cat expected.sql)"
}

@test "leaves the original dump untouched" {
    cp dump.sql original.sql
    "$UTILS/strip-mysqldump-definers.sh" --path=dump.sql --output=out.sql 2>/dev/null
    run cmp dump.sql original.sql
    assert_success
}

@test "refuses to overwrite an existing output file" {
    echo original > out.sql
    run "$UTILS/strip-mysqldump-definers.sh" --path=dump.sql --output=out.sql
    assert_failure
    assert_output --partial 'already exists'
    assert_equal "$(cat out.sql)" original
}

@test "rejects a missing input file" {
    run "$UTILS/strip-mysqldump-definers.sh" --path=nope.sql --output=out.sql
    assert_failure
    assert_output --partial 'no such file'
    assert [ ! -e out.sql ]
}
