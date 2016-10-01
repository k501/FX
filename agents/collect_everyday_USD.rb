# coding: utf-8

require 'jiji/model/agents/agent'
require 'date'
require 'httpclient'
require 'json'

# trading robot by TensorFlow
class TensorFlowUsd

  # エージェントとして登録する
  include Jiji::Model::Agents::Agent

  def self.description
    <<-STR
trading robot by TensorFlow
      STR
  end

  def self.property_infos
    [
      Property.new('exec_mode',
        '動作モード("collect" or "trade" or "test")', "collect")
    ]
  end

  # 01.初期化処理の実行
  def post_create
    @calculator = SignalCalculator.new(broker)
    # ユーティリティ
    # 先行指標と遅行指標を受け取って、クロスアップ/クロスダウンを判定するユーティリティ
    @cross = Cross.new
    # 動作モードで指定した値でcollect/trade/testを分ける
    @mode  = create_mode(@exec_mode)
    @graph = graph_factory.create('移動平均',
      :rate, :last, ['#FF6633', '#FFAA22'])
  end

  # 02.レート情報の処理
  # 15秒ごとにループして実行される、たぶん
  def next_tick(tick)
    date = tick.timestamp.to_date
    # current_dateに本日の日付が代入されていたら処理しない（1日一回しか処理しない）
    return if !@current_date.nil? && @current_date == date
    @current_date = date

    signal = @calculator.next_tick(tick)
    @cross.next_data(signal[:ma5], signal[:ma10])

    @graph << [signal[:ma5], signal[:ma10]]
    do_trade(signal)
  end

  def do_trade(signal)
    # 5日移動平均と10日移動平均のクロスでトレード
    # if @cross.cross_up?
    #   buy(signal)
    # elsif @cross.cross_down?
    #   sell(signal)
    # end

    # 多くのデータを取得したいので、毎日、買建てを仕込む
    buy(signal)

  end

  def buy(signal)
    # 既存のポジションを決済する
    close_exist_positions
    return unless @mode.do_trade?(signal, "buy")
    # 買う
    result = broker.buy(:USDJPY, 10000)
    @current_position = broker.positions[result.trade_opened.internal_id]
    @current_signal = signal
  end


  def sell(signal)
    close_exist_positions
    return unless @mode.do_trade?(signal, "sell")
    # 売る
    result = broker.sell(:USDJPY, 10000)
    @current_position = broker.positions[result.trade_opened.internal_id]
    @current_signal = signal
  end

  def close_exist_positions
    # @current_positionがnilならリターン
    return unless @current_position
    @current_position.close
    @mode.after_position_closed( @current_signal, @current_position )
    @current_position = nil
    @current_signal = nil
  end

  def create_mode(mode)
    case mode
    when 'trade' then
      TradeMode.new
    when 'collect' then
      CollectMode.new
    else
      TestMode.new
    end
  end

  # -------------------------------------------------------------
  # collect :データ収集モード
  #
  # TensorFlowでの予測を使用せずに
  # 移動平均のシグナルのみでトレードを行い、
  # 結果をDBに保存する
  # -------------------------------------------------------------
  class CollectMode
    def do_trade?(signal, sell_or_buy)
      true
    end
    # ポジションが閉じられたら、トレード結果とシグナルをDBに登録する
    def after_position_closed( signal, position )
      TradeAndSignals.create_from( signal, position).save
    end
  end

  # -------------------------------------------------------------
  # test :テストモード
  #
  # TensorFlowでの予測を使用せずに
  # 移動平均のシグナルのみでトレードする.
  # トレード結果は収集しない
  # -------------------------------------------------------------
  class TestMode
    def do_trade?(signal, sell_or_buy)
      true
    end
    def after_position_closed( signal, position )
      # do nothing.
    end
  end

  # -------------------------------------------------------------
  # trade :取引モード
  #
  # TensorFlowでの予測を使用してトレードする。
  # トレード結果は収集しない
  # -------------------------------------------------------------
  class TradeMode
    def initialize
      @client = HTTPClient.new
    end
    # 勝敗予測をtensorflowに問い合わせる
    def do_trade?(signal, sell_or_buy)
      body = {sell_or_buy: sell_or_buy}.merge(signal)
      body.delete(:ma5)
      body.delete(:ma10)
      result = @client.post("http://tensorflow:5000/api/estimator", {
        body: JSON.generate(body),
        header: {
          'Content-Type' => 'application/json'
        }
      })
      return JSON.parse(result.body)["result"] == "up"
      # up と予測された場合のみトレード
    end
    def after_position_closed( signal, position )
      # do nothing.
    end
  end
end


# トレード結果とその時の各種指標。
# MongoDBに格納してTensorFlowの学習データにする
class TradeAndSignals

  include Mongoid::Document

  store_in collection: 'trade_data'
  # collectionのデータ型を定義
  field :macd_difference,    type: Float # macd - macd_signal

  field :rsi,                type: Float

  field :slope_10,           type: Float # 10日移動平均線の傾き
  field :slope_25,           type: Float # 25日移動平均線の傾き
  field :slope_50,           type: Float # 50日移動平均線の傾き

  field :ma_10_estrangement, type: Float # 10日移動平均からの乖離率
  field :ma_25_estrangement, type: Float
  field :ma_50_estrangement, type: Float

  field :profit_or_loss,     type: Float
  field :sell_or_buy,        type: Symbol
  field :entered_at,         type: Time
  field :exited_at,          type: Time

  # DBに格納するデータを整形？？
  def self.create_from( signal_data, position )
    TradeAndSignals.new do |ts|
      signal_data.each do |pair|
        next if pair[0] == :ma5|| pair[0] == :ma10
        ts.send( "#{pair[0]}=".to_sym, pair[1] )
      end
      ts.profit_or_loss = position.profit_or_loss
      ts.sell_or_buy    = position.sell_or_buy
      ts.entered_at     = position.entered_at
      ts.exited_at      = position.exited_at
    end
  end
end

# Jijiに標準搭載されているSignalsライブラリを利用して指標を計算するクラス
class SignalCalculator

  def initialize(broker)
    @broker = broker
  end

  def next_tick(tick)
    prepare_signals(tick) unless @macd
    calculate_signals(tick[:USDJPY])
  end

  def calculate_signals(tick)
    price = tick.bid
    macd = @macd.next_data(price)
    ma5  = @ma5.next_data(price)
    ma10 = @ma10.next_data(price)
    ma25 = @ma25.next_data(price)
    ma50 = @ma50.next_data(price)
    {
      ma5:  ma5,
      ma10: ma10,
      macd_difference: macd ? macd[:macd] - macd[:signal] : nil,
      rsi:  @rsi.next_data(price),
      slope_10: ma10 ? @ma10v.next_data(ma10) : nil,
      slope_25: ma25 ? @ma25v.next_data(ma25) : nil,
      slope_50: ma50 ? @ma50v.next_data(ma50) : nil,
      ma_10_estrangement: ma10 ? calculate_estrangement(price, ma10) : nil,
      ma_25_estrangement: ma25 ? calculate_estrangement(price, ma25) : nil,
      ma_50_estrangement: ma50 ? calculate_estrangement(price, ma50) : nil
    }
  end

  def prepare_signals(tick)
    create_signals
    retrieve_rates(tick.timestamp).each do |rate|
      calculate_signals(rate.close)
    end
  end

  # JijiのSignalsクラスで指数を計算
  def create_signals

    @macd  = Signals::MACD.new
    @ma5   = Signals::MovingAverage.new(5)
    @ma10  = Signals::MovingAverage.new(10)
    @ma25  = Signals::MovingAverage.new(25)
    @ma50  = Signals::MovingAverage.new(50)
    @ma5v  = Signals::Vector.new(5)
    @ma10v = Signals::Vector.new(10)
    @ma25v = Signals::Vector.new(25)
    @ma50v = Signals::Vector.new(50)
    @rsi   = Signals::RSI.new(9)
  end

  # Jijiのretrieve_ratesメソッドで過去のレート情報を取得する
  def retrieve_rates(time)
    # 引数で、通貨ペア、集計期間、取得開始日時、取得終了日時を指定します。
    # 集計期間には、以下のいずれかを指定できます。
    #   :fifteen_seconds .. 15秒足
    #   :one_minute      .. 分足
    #   :fifteen_minutes .. 15分足
    #   :thirty_minutes  .. 30分足
    #   :one_hour        .. 1時間足
    #   :six_hours       .. 6時間足
    #   :one_day         .. 日足
    #
    @broker.retrieve_rates(:USDJPY, :one_day, time - 60*60*24*60, time )
  end

  def calculate_estrangement(price, ma)
    ((BigDecimal.new(price, 10) - ma) / ma * 100).to_f
  end

end
