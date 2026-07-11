interface BarnyardConnectionReaderState
  fun name(): String
  fun enter(conn: BarnyardConnection ref): None => None
  fun read(conn: BarnyardConnection ref, data: ByteSeq val): BarnyardConnectionTransition box

interface BarnyardConnectionWriterState
  fun name(): String
  fun enter(conn: BarnyardConnection ref): None => None
  fun write(conn: BarnyardConnection ref): BarnyardConnectionTransition box

interface BarnyardConnectionIdleState
  fun name(): String
  fun enter(conn: BarnyardConnection ref): None => None
  fun wake(conn: BarnyardConnection ref, peer: BarnyardConnection tag): BarnyardConnectionTransition box

interface BarnyardConnectionPipingState
  fun name(): String
  fun enter(conn: BarnyardConnection ref): None => None
  fun pipe(conn: BarnyardConnection, data: ForwardData): BarnyardConnectionTransition box
  fun closed(conn: BarnyardConnection ref): None => None

primitive BarnyardConnectionHardClose
  fun name(): String => "HardClose"
  fun enter(conn: BarnyardConnection ref): None => None

primitive BarnyardConnectionClose
  fun name(): String => "Close"
  fun enter(conn: BarnyardConnection ref): None => None

type BarnyardConnectionInteractableState is (BarnyardConnectionWriterState | BarnyardConnectionReaderState | BarnyardConnectionIdleState | BarnyardConnectionPipingState)
type BarnyardConnectionTransition is (BarnyardConnectionReaderState | BarnyardConnectionWriterState | BarnyardConnectionHardClose | BarnyardConnectionClose | BarnyardConnectionIdleState | BarnyardConnectionPipingState)
