class LegalController < ApplicationController
  skip_before_action :authenticate_user!

  def index
  end

  def terminos
  end

  def privacidad
  end

  def tarjetas_regalo
  end

  def pagos_reembolsos
  end

  def uso_aceptable
  end

  def eliminacion_datos
  end
end

