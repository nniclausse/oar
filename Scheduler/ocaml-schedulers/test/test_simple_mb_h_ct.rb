def resources_init_dsllab
  DB << "TRUNCATE resource_logs;"
  oar_sql_file "resources_dsllab_40nodes.sql"
end

def test_base
  10.times do |i|  oar_job_insert(:res=>"resource_id=#{4*(i+1)}",:walltime=> i * 500 )  ; end
end

def test_ct_0
  jid1 = oar_job_insert(:res => "resource_id=20", :walltime => 7200, :types => "container")
  jid2 = oar_job_insert(:res => "resource_id=10", :walltime => 2200, :types => "inner=#{jid1}")
end