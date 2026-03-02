mod Test.Portable.Channel {

    @Test
    def basic01(): Unit \ {Chan, NonDet} =
        let (tx, rx) = Channel.buffered(1);
        Channel.send(42, tx);
        discard Channel.recv(rx)

    pub def runAll(): Unit \ {Chan, NonDet} = {
        let _ = basic01();
        ()
    }

}
