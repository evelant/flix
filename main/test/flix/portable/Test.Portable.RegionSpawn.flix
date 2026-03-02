mod Test.Portable.RegionSpawn {

    def assertTrue(cond: Bool, msg: String): Unit =
        if (cond) () else bug!(msg)

    @Test
    def childExceptionPrecedence01(): Unit \ IO = {
        let v = try {
            region rc {
                spawn { throw Exn.mk(1); () } @ rc;
                ()
            };
            0
        } catch {
            case exn: Int32 => Exn.payloadAs(exn)
            case _: Exn => -1
        };
        assertTrue(v == 1, "childExceptionPrecedence01 failed.")
    }

    @Test
    def childExceptionPrecedence02(): Unit \ IO = {
        let v = try {
            region rc {
                spawn { throw Exn.mk(1); () } @ rc;
                throw Exn.mk(2);
                ()
            };
            0
        } catch {
            case exn: Int32 => Exn.payloadAs(exn)
            case _: Exn => -1
        };
        assertTrue(v == 1, "childExceptionPrecedence02 failed.")
    }

    pub def runAll(): Unit \ IO = {
        let _ = childExceptionPrecedence01();
        let _ = childExceptionPrecedence02();
        ()
    }

}
