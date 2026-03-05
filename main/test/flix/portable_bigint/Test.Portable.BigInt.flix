mod Test.Portable.BigInt {

    @Test
    def fromStringOk01(): Unit =
        match BigInt.fromString("  +123  ") {
            case Some(v) if v == 123ii => ()
            case _ => bug!("expected BigInt.fromString to succeed.")
        }

    @Test
    def fromStringErr01(): Unit =
        match BigInt.fromString("abc") {
            case None => ()
            case _ => bug!("expected BigInt.fromString to fail.")
        }

    @Test
    def fromStringErr02(): Unit =
        match BigInt.fromString("1_000") {
            case None => ()
            case _ => bug!("expected BigInt.fromString to reject underscores.")
        }

    @Test
    def toStringRoundtrip01(): Unit = {
        let x = BigInt.leftShift(1ii, 64i32);
        if (BigInt.toString(x) != "18446744073709551616")
            bug!("unexpected BigInt.toString output.");
        match BigInt.fromString(BigInt.toString(x)) {
            case Some(y) if y == x => ()
            case _ => bug!("expected BigInt roundtrip to succeed.")
        }
    }

    @Test
    def arith01(): Unit = {
        if (1ii + 2ii != 3ii) bug!("add failed.");
        if (10ii - 3ii != 7ii) bug!("sub failed.");
        if (7ii * 6ii != 42ii) bug!("mul failed.");
        ()
    }

    @Test
    def divRem01(): Unit = {
        if (10ii / 3ii != 3ii) bug!("div failed.");
        if (BigInt.remainder(10ii, 3ii) != 1ii) bug!("rem failed.");

        if (-7ii / 3ii != -2ii) bug!("neg div failed.");
        if (BigInt.remainder(-7ii, 3ii) != -1ii) bug!("neg rem failed.");

        if (7ii / -3ii != -2ii) bug!("neg divisor div failed.");
        if (BigInt.remainder(7ii, -3ii) != 1ii) bug!("neg divisor rem failed.");
        ()
    }

    @Test
    def shift01(): Unit = {
        if (BigInt.leftShift(1ii, 32i32) != 4294967296ii) bug!("shl failed.");
        if (BigInt.leftShift(1ii, -1i32) != 0ii) bug!("shl negative failed.");
        if (BigInt.rightShift(1ii, -1i32) != 2ii) bug!("shr negative failed.");
        if (BigInt.rightShift(-1ii, 1i32) != -1ii) bug!("shr sign-ext failed.");
        ()
    }

    @Test
    def bitwise01(): Unit = {
        if (BigInt.bitwiseNot(0ii) != -1ii) bug!("not failed.");
        if (BigInt.bitwiseNot(-1ii) != 0ii) bug!("not -1 failed.");
        if (BigInt.bitwiseAnd(-1ii, 255ii) != 255ii) bug!("and failed.");
        if (BigInt.bitwiseOr(1ii, 2ii) != 3ii) bug!("or failed.");
        if (BigInt.bitwiseXor(1ii, 3ii) != 2ii) bug!("xor failed.");
        ()
    }

    @Test
    def bitLength01(): Unit = {
        if (BigInt.log2(0ii) != 0i32) bug!("bitLength(0) failed.");
        if (BigInt.log2(1ii) != 1i32) bug!("bitLength(1) failed.");
        if (BigInt.log2(2ii) != 2i32) bug!("bitLength(2) failed.");
        if (BigInt.log2(-1ii) != 0i32) bug!("bitLength(-1) failed.");
        if (BigInt.log2(-2ii) != 1i32) bug!("bitLength(-2) failed.");
        if (BigInt.log2(-3ii) != 2i32) bug!("bitLength(-3) failed.");
        if (BigInt.log2(BigInt.leftShift(1ii, 32i32)) != 33i32) bug!("bitLength(2^32) failed.");
        ()
    }

    @Test
    def hash01(): Unit = {
        if (Hash.hash(0ii) != 0i32) bug!("hash(0) failed.");
        if (Hash.hash(1ii) != 1i32) bug!("hash(1) failed.");
        if (Hash.hash(-1ii) != -1i32) bug!("hash(-1) failed.");
        if (Hash.hash(BigInt.leftShift(1ii, 32i32)) != 31i32) bug!("hash(2^32) failed.");
        if (Hash.hash(BigInt.leftShift(1ii, 64i32)) != 961i32) bug!("hash(2^64) failed.");
        ()
    }

    pub def runAll(): Unit = {
        let _ = fromStringOk01();
        let _ = fromStringErr01();
        let _ = fromStringErr02();
        let _ = toStringRoundtrip01();
        let _ = arith01();
        let _ = divRem01();
        let _ = shift01();
        let _ = bitwise01();
        let _ = bitLength01();
        let _ = hash01();
        ()
    }

}

